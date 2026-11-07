-- 미래몰 공병수불/장기미회수/변상정산/일별회수 (deposit.sql 적용 후 실행)
-- 라이브 미적용. 전체를 한 번에 실행. 반복 실행 가능. 기존 mm_save의 증빙/재고/주문 기능 유지.
begin;
alter table public.mm_deposit drop constraint if exists mm_deposit_kind_check;
alter table public.mm_deposit add constraint mm_deposit_kind_check check(kind in ('out','in','settle'));
alter table public.mm_deposit add column if not exists settlement_id text;
create index if not exists mm_deposit_at_idx on public.mm_deposit(at, user_id);
create index if not exists mm_deposit_user_at_idx on public.mm_deposit(user_id, at, id);
create table if not exists public.mm_deposit_settings (
  id boolean primary key default true check(id), overdue_days integer not null default 60 check(overdue_days between 1 and 36500)
);
insert into public.mm_deposit_settings(id) values(true) on conflict do nothing;
create table if not exists public.mm_deposit_settlements (
  id text primary key, user_id text not null, by_id text not null, at timestamptz not null default now(),
  items jsonb not null, amount numeric not null check(amount>=0), memo text not null, receipt jsonb not null
);
alter table public.mm_deposit_settings enable row level security;
alter table public.mm_deposit_settlements enable row level security;
revoke all on public.mm_deposit_settings, public.mm_deposit_settlements, public.mm_deposit from public, anon, authenticated;
revoke all on sequence public.mm_deposit_id_seq from public, anon, authenticated;

create or replace function public.mm_save(p_token text, p_rows jsonb, p_kv jsonb, p_dels jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare me jsonb := mm_me(p_token); role text := me->>'role'; uid text := me->>'id';
  r jsonb; c text; i text; d jsonb; ex jsonb; skipped int := 0; it jsonb; m jsonb; u jsonb;
  items jsonb; mid text; ev jsonb; et text; en text; eb text; q int; supply numeric; earn numeric; vat numeric; bal numeric; used numeric;
  dep numeric; ret jsonb; rit jsonb; rbot int; rbox int; ramt numeric; obot bigint; obox bigint;
  bpp int; bdep numeric; xdep numeric; catn text; mrow record;
begin
  perform pg_advisory_xact_lock(72611402);
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    c := r->>'coll'; i := r->>'id'; d := r->'data';
    select data into ex from mm_rows where coll = c and id = i for update;
    if c in ('categories', 'menus') and role = 'boss' or c = 'posts' and role in ('boss', 'staff')
       or c = 'requests' and role = 'boss' or c = 'favorites' and i = uid then
      null;
    elsif c = 'requests' and role = 'staff' and ex is null and d->>'by' = uid then
      d := d || '{"status":"pending"}';
    elsif c = 'users' and ex is not null and (role = 'boss' or role = 'staff' and ex->>'role' = 'customer' and d->>'status' in ('active', 'rejected')) then
      d := ex || jsonb_build_object('status', coalesce(d->>'status', ex->>'status'));
      if role = 'boss' then
        d := d || jsonb_build_object('name', coalesce(r->'data'->>'name', ex->>'name'));
        if length(coalesce(r->'data'->>'pw', '')) >= 4 then d := d || jsonb_build_object('pwh', crypt(r->'data'->>'pw', gen_salt('bf', 8))); end if;
      end if;
    elsif c = 'orders' and ex is not null and role in ('boss', 'staff') then
      d := ex || jsonb_build_object('status', coalesce(d->>'status', ex->>'status'));
      -- 완료 시각(doneAt, epoch ms): 완료로 바뀔 때 기록, 완료에서 벗어나면 제거
      -- 완료 전 회수수량 수정 허용(서버 재계산)
      if ex->>'status' is distinct from '완료' and jsonb_typeof(r->'data'->'returns') = 'array' then
        ret := '[]'; ramt := 0;
        if exists (select 1 from jsonb_array_elements(coalesce(r->'data'->'returns','[]')) z group by z->>'menuId' having count(*)>1) then raise exception 'DUPLICATE_ITEM'; end if;
        for rit in select * from jsonb_array_elements(r->'data'->'returns') loop
          select id, data into mid, m from mm_rows where coll = 'menus' and id = rit->>'menuId';
          continue when mid is null;
          bdep := greatest(coalesce((m->>'bottleDep')::numeric, 0), 0);
          xdep := greatest(coalesce((m->>'boxDep')::numeric, 0), 0);
          rbot := least(greatest(coalesce((rit->>'bottles')::int, 0), 0), 1000000);
          rbox := least(greatest(coalesce((rit->>'boxes')::int, 0), 0), 1000000);
          select coalesce(sum(case when kind='out' then bottles else -bottles end),0),
                 coalesce(sum(case when kind='out' then boxes else -boxes end),0)
            into obot, obox from mm_deposit where user_id = ex->>'userId' and menu_id = mid;
          if rbot > obot or rbox > obox then raise exception 'RETURN_OVER' using errcode = 'P0001'; end if;
          continue when rbot = 0 and rbox = 0;
          ret := ret || jsonb_build_object('menuId', mid, 'name', m->>'name', 'bottles', rbot, 'boxes', rbox,
            'bottleDep', bdep, 'boxDep', xdep, 'amount', rbot * bdep + rbox * xdep);
          ramt := ramt + rbot * bdep + rbox * xdep;
        end loop;
        dep := coalesce((ex->>'deposit')::numeric, 0);
        d := d || jsonb_build_object('returns', ret, 'returnTotal', ramt,
          'orderPrice', coalesce((ex->>'supply')::numeric,0) + coalesce((ex->>'vat')::numeric,0) - coalesce((ex->>'used')::numeric,0) + dep,
          'total', greatest(coalesce((ex->>'supply')::numeric,0) + coalesce((ex->>'vat')::numeric,0) - coalesce((ex->>'used')::numeric,0) + dep - ramt, 0));
      end if;
      if d->>'status' = '완료' and ex->>'status' is distinct from '완료' then
        d := d || jsonb_build_object('doneAt', (extract(epoch from now()) * 1000)::bigint);
        -- 주류 출고(보증금) 기록
        for it in select * from jsonb_array_elements(coalesce(d->'items', '[]')) loop
          select id, data into mid, m from mm_rows where coll = 'menus' and (id = it->>'menuId' or data->>'name' = it->>'name') limit 1;
          continue when mid is null;
          select coalesce(c.data->>'name','') into catn from mm_rows c where c.coll = 'categories' and c.id = m->>'categoryId';
          bpp := greatest(coalesce((m->>'bottlesPerBox')::int, 0), 0);
          bdep := greatest(coalesce((m->>'bottleDep')::numeric, 0), 0);
          xdep := greatest(coalesce((m->>'boxDep')::numeric, 0), 0);
          continue when catn is distinct from '주류' and bpp = 0 and bdep = 0 and xdep = 0;
          q := greatest(coalesce((it->>'qty')::int, 0), 0);
          continue when q = 0;
          insert into mm_deposit(kind, user_id, menu_id, order_id, boxes, bottles, bottle_dep, box_dep, amount, by_id, by_name, memo)
            values ('out', d->>'userId', mid, i, q, q * bpp, bdep, xdep, q * bpp * bdep + q * xdep, me->>'id', me->>'name', '주문출고');
        end loop;
        -- 회수 확정
        for rit in select * from jsonb_array_elements(coalesce(d->'returns', '[]')) loop
          rbot := coalesce((rit->>'bottles')::int, 0); rbox := coalesce((rit->>'boxes')::int, 0);
          continue when rbot = 0 and rbox = 0;
          select coalesce(sum(case when kind='out' then bottles else -bottles end),0),
                 coalesce(sum(case when kind='out' then boxes else -boxes end),0)
            into obot, obox from mm_deposit where user_id=d->>'userId' and menu_id=rit->>'menuId';
          if rbot>obot or rbox>obox then raise exception 'RETURN_OVER'; end if;
          insert into mm_deposit(kind, user_id, menu_id, order_id, boxes, bottles, bottle_dep, box_dep, amount, by_id, by_name, memo)
            values ('in', d->>'userId', rit->>'menuId', i, rbox, rbot,
              coalesce((rit->>'bottleDep')::numeric,0), coalesce((rit->>'boxDep')::numeric,0),
              coalesce((rit->>'amount')::numeric, rbot*coalesce((rit->>'bottleDep')::numeric,0)+rbox*coalesce((rit->>'boxDep')::numeric,0)),
              me->>'id', me->>'name', '주문회수');
        end loop;
      elsif d->>'status' is distinct from '완료' then
        d := d - 'doneAt';
        if ex->>'status' = '완료' then
          if exists (select 1 from mm_deposit z where z.user_id=ex->>'userId'
            group by z.menu_id having
              sum(case when z.order_id=i then 0 when z.kind='out' then z.bottles else -z.bottles end)<0 or
              sum(case when z.order_id=i then 0 when z.kind='out' then z.boxes else -z.boxes end)<0)
          then raise exception 'DEPOSIT_ALREADY_RETURNED'; end if;
          delete from mm_deposit where order_id = i;
        end if;
      end if;
      d := d
        || case when jsonb_typeof(r->'data'->'evidenceIssued') = 'object' and ex->'evidenceIssued' is null
             then jsonb_build_object('evidenceIssued', jsonb_build_object('at', (extract(epoch from now()) * 1000)::bigint, 'by', me->>'name')) else '{}' end;
    elsif c = 'orders' and ex is null and role = 'customer' and d->>'userId' = uid then
      select data into u from mm_rows where coll = 'users' and id = uid for update;
      items := '[]'; supply := 0; earn := 0; dep := 0;
      for it in select * from jsonb_array_elements(coalesce(d->'items', '[]')) loop
        q := least(greatest(coalesce((it->>'qty')::numeric, 0), 0), 100000)::int;
        select id, data into mid, m from mm_rows where coll = 'menus' and data->>'name' = it->>'name' and data->>'status' = 'active' limit 1;
        continue when m is null or q <= 0;
        select coalesce(c.data->>'name','') into catn from mm_rows c where c.coll = 'categories' and c.id = m->>'categoryId';
        bpp := greatest(coalesce((m->>'bottlesPerBox')::int, 0), 0);
        bdep := greatest(coalesce((m->>'bottleDep')::numeric, 0), 0);
        xdep := greatest(coalesce((m->>'boxDep')::numeric, 0), 0);
        if catn = '주류' or bpp > 0 or bdep > 0 or xdep > 0 then
          items := items || jsonb_build_object('menuId', mid, 'name', m->>'name', 'qty', q, 'price', (m->>'price')::numeric, 'mileage', coalesce((m->>'mileage')::numeric, 0),
            'boxes', q, 'bottles', q * bpp, 'bottleDep', bdep, 'boxDep', xdep, 'deposit', q * bpp * bdep + q * xdep);
          dep := coalesce(dep, 0) + q * bpp * bdep + q * xdep;
        else
          items := items || jsonb_build_object('menuId', mid, 'name', m->>'name', 'qty', q, 'price', (m->>'price')::numeric, 'mileage', coalesce((m->>'mileage')::numeric, 0));
        end if;
        supply := supply + q * (m->>'price')::numeric; earn := earn + q * coalesce((m->>'mileage')::numeric, 0);
      end loop;
      if jsonb_array_length(items) = 0 then skipped := skipped + 1; continue; end if;
      earn := 0; -- 적립 없음 (2026-11-04)
      vat := round(supply * 0.1); bal := coalesce((u->>'mileage')::numeric, 0);
      used := least(greatest(coalesce((d->>'used')::numeric, 0), 0), bal, supply + vat);
      dep := coalesce(dep, 0);
      ret := '[]'; ramt := 0;
        if exists (select 1 from jsonb_array_elements(coalesce(r->'data'->'returns','[]')) z group by z->>'menuId' having count(*)>1) then raise exception 'DUPLICATE_ITEM'; end if;
      for rit in select * from jsonb_array_elements(coalesce(r->'data'->'returns', '[]')) loop
        select id, data into mid, m from mm_rows where coll = 'menus' and id = rit->>'menuId';
        continue when mid is null;
        bdep := greatest(coalesce((m->>'bottleDep')::numeric, 0), 0);
        xdep := greatest(coalesce((m->>'boxDep')::numeric, 0), 0);
        rbot := least(greatest(coalesce((rit->>'bottles')::int, 0), 0), 1000000);
        rbox := least(greatest(coalesce((rit->>'boxes')::int, 0), 0), 1000000);
        select coalesce(sum(case when kind='out' then bottles else -bottles end),0),
               coalesce(sum(case when kind='out' then boxes else -boxes end),0)
          into obot, obox from mm_deposit where user_id = uid and menu_id = mid;
        if rbot > obot or rbox > obox then raise exception 'RETURN_OVER' using errcode = 'P0001'; end if;
        continue when rbot = 0 and rbox = 0;
        ret := ret || jsonb_build_object('menuId', mid, 'name', m->>'name', 'bottles', rbot, 'boxes', rbox,
          'bottleDep', bdep, 'boxDep', xdep, 'amount', rbot * bdep + rbox * xdep);
        ramt := ramt + rbot * bdep + rbox * xdep;
      end loop;
      d := jsonb_build_object('id', i, 'userId', uid, 'name', u->>'name', 'phone', u->>'phone', 'items', items, 'supply', supply, 'vat', vat,
             'used', used, 'deposit', dep, 'returns', ret, 'returnTotal', ramt,
             'orderPrice', supply + vat - used + dep, 'total', greatest(supply + vat - used + dep - ramt, 0),
             'earn', earn, 'status', '입금대기', 'at', (extract(epoch from now()) * 1000)::bigint);
      et := r->'data'->'evidence'->>'type'; ev := '{"type":"none"}';
      en := regexp_replace(coalesce(r->'data'->'evidence'->>'no', ''), '\D', '', 'g');
      eb := regexp_replace(coalesce(r->'data'->'evidence'->>'bizNo', ''), '\D', '', 'g');
      if et = 'cash' and en ~ '^01[0-9]{8,9}$' then ev := jsonb_build_object('type', 'cash', 'no', en);
      elsif et = 'tax' and length(eb) = 10 then
        ev := jsonb_build_object('type', 'tax', 'bizNo', eb);
        update mm_rows set data = data || jsonb_build_object('taxInfo', jsonb_build_object('bizNo', eb)) where coll = 'users' and id = uid;
      end if;
      d := d || jsonb_build_object('evidence', ev);
      update mm_rows set data = data || jsonb_build_object('mileage', bal - used + earn), updated_at = now() where coll = 'users' and id = uid;
    else
      skipped := skipped + 1; continue;
    end if;
    insert into mm_rows(coll, id, pos, data, updated_at) values (c, i, coalesce((r->>'pos')::bigint, 0), d, now())
      on conflict (coll, id) do update set data = excluded.data, updated_at = now();
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p_kv, '[]')) loop
    if r->>'key' = 'popup' and role in ('boss', 'staff') or r->>'key' in ('changelog', 'version') and role = 'boss'
       or r->>'key' in ('hometax_request', 'hometax_pending') and role in ('boss', 'staff') then
      insert into mm_kv(key, value, updated_at) values (r->>'key', r->'value', now()) on conflict (key) do update set value = excluded.value, updated_at = now();
    else skipped := skipped + 1; end if;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p_dels, '[]')) loop
    if role = 'boss' and r->>0 <> 'users' then delete from mm_rows where coll = r->>0 and id = r->>1; else skipped := skipped + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'skipped', skipped);
end $$;

create or replace function public.mm_deposit_return(p_token text, p_user text, p_items jsonb, p_memo text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare me jsonb := mm_me(p_token); rit jsonb; mid text; m jsonb; rbot int; rbox int; bdep numeric; xdep numeric;
  obot bigint; obox bigint; lines jsonb := '[]'; total numeric := 0; nid bigint; ids bigint[] := '{}';
begin
  if coalesce(me->>'role','') not in ('boss', 'staff') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(72611402);
  if exists (select 1 from jsonb_array_elements(coalesce(p_items,'[]')) z group by z->>'menuId' having count(*)>1) then raise exception 'DUPLICATE_ITEM'; end if;
  if not exists (select 1 from mm_rows where coll='users' and id=p_user and data->>'role'='customer') then raise exception 'NO_USER'; end if;
  for rit in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    select id, data into mid, m from mm_rows where coll='menus' and id = rit->>'menuId';
    if mid is null then raise exception 'NO_MENU'; end if;
    bdep := greatest(coalesce((m->>'bottleDep')::numeric, 0), 0);
    xdep := greatest(coalesce((m->>'boxDep')::numeric, 0), 0);
    rbot := least(greatest(coalesce((rit->>'bottles')::int, 0), 0), 1000000);
    rbox := least(greatest(coalesce((rit->>'boxes')::int, 0), 0), 1000000);
    select coalesce(sum(case when kind='out' then bottles else -bottles end),0),
           coalesce(sum(case when kind='out' then boxes else -boxes end),0)
      into obot, obox from mm_deposit where user_id = p_user and menu_id = mid;
    if rbot > obot or rbox > obox then raise exception 'RETURN_OVER' using errcode = 'P0001'; end if;
    continue when rbot = 0 and rbox = 0;
    insert into mm_deposit(kind, user_id, menu_id, boxes, bottles, bottle_dep, box_dep, amount, by_id, by_name, memo)
      values ('in', p_user, mid, rbox, rbot, bdep, xdep, rbot*bdep + rbox*xdep, me->>'id', me->>'name', left(coalesce(p_memo,''), 200))
      returning id into nid;
    ids := ids || nid;
    lines := lines || jsonb_build_object('id', nid, 'menuId', mid, 'name', m->>'name', 'bottles', rbot, 'boxes', rbox,
      'bottleDep', bdep, 'boxDep', xdep, 'amount', rbot*bdep + rbox*xdep);
    total := total + rbot*bdep + rbox*xdep;
  end loop;
  if jsonb_array_length(lines) = 0 then raise exception 'EMPTY'; end if;
  return jsonb_build_object('ok', true, 'amount', total, 'lines', lines, 'ids', to_jsonb(ids),
    'at', (extract(epoch from now())*1000)::bigint, 'by', me->>'name',
    'userId', p_user, 'userName', (select data->>'name' from mm_rows where coll='users' and id=p_user));
end $$;


-- 설정은 별도 테이블: 고객에게 mm_fetch로 노출되지 않고 사장만 변경.
create or replace function public.mm_deposit_config(p_token text, p_days integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare me jsonb:=public.mm_me(p_token);
begin
  if coalesce(me->>'role','')<>'boss' then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if p_days is null or p_days<1 or p_days>36500 then raise exception 'INVALID_DAYS'; end if;
  update public.mm_deposit_settings set overdue_days=p_days where id=true;
  return jsonb_build_object('ok',true,'overdueDays',p_days);
end $$;

-- 변상금은 보증금 감소액과 별도 저장하며 VAT를 계산/발행하지 않는다.
create or replace function public.mm_deposit_settle(p_token text, p_user text, p_items jsonb, p_amount numeric, p_memo text, p_request text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare me jsonb:=public.mm_me(p_token); z jsonb; m jsonb; b bigint; x bigint; ob bigint; ox bigint;
  bd numeric; xd numeric; nid bigint; lines jsonb:='[]'; res jsonb; prev public.mm_deposit_settlements%rowtype;
  stamp timestamptz:=clock_timestamp();
begin
  if coalesce(me->>'role','')<>'boss' then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if p_request is null or length(p_request)<16 or length(p_request)>100 then raise exception 'INVALID_REQUEST'; end if;
  if p_amount is null or p_amount<0 or p_amount>100000000000 or p_amount<>round(p_amount,2) then raise exception 'INVALID_AMOUNT'; end if;
  if length(trim(coalesce(p_memo,'')))=0 or length(p_memo)>500 then raise exception 'REASON_REQUIRED'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'EMPTY'; end if;
  perform pg_catalog.pg_advisory_xact_lock(72611402);
  select * into prev from public.mm_deposit_settlements where id=p_request;
  if found then
    if prev.user_id<>p_user or prev.by_id<>me->>'id' or prev.items<>p_items or prev.amount<>p_amount or prev.memo<>p_memo then raise exception 'REQUEST_CONFLICT'; end if;
    return prev.receipt;
  end if;
  if not exists(select 1 from public.mm_rows where coll='users' and id=p_user and data->>'role'='customer') then raise exception 'NO_USER'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) a group by a->>'menuId' having count(*)>1) then raise exception 'DUPLICATE_ITEM'; end if;
  for z in select * from jsonb_array_elements(p_items) loop
    b:=coalesce((z->>'bottles')::bigint,0); x:=coalesce((z->>'boxes')::bigint,0);
    if b<0 or x<0 or b>1000000 or x>1000000 then raise exception 'INVALID_QTY'; end if;
    continue when b=0 and x=0;
    select data into m from public.mm_rows where coll='menus' and id=z->>'menuId';
    if m is null then raise exception 'NO_MENU'; end if;
    select coalesce(sum(case when kind='out' then bottles else -bottles end),0),
           coalesce(sum(case when kind='out' then boxes else -boxes end),0)
      into ob,ox from public.mm_deposit where user_id=p_user and menu_id=z->>'menuId';
    if b>ob or x>ox then raise exception 'RETURN_OVER'; end if;
    bd:=greatest(coalesce((m->>'bottleDep')::numeric,0),0); xd:=greatest(coalesce((m->>'boxDep')::numeric,0),0);
    insert into public.mm_deposit(kind,user_id,menu_id,bottles,boxes,bottle_dep,box_dep,amount,by_id,by_name,at,memo,settlement_id)
      values('settle',p_user,z->>'menuId',b,x,bd,xd,b*bd+x*xd,me->>'id',me->>'name',stamp,p_memo,p_request) returning id into nid;
    lines:=lines||jsonb_build_object('id',nid,'menuId',z->>'menuId','name',m->>'name','bottles',b,'boxes',x,'amount',b*bd+x*xd);
  end loop;
  if jsonb_array_length(lines)=0 then raise exception 'EMPTY'; end if;
  res:=jsonb_build_object('ok',true,'id',p_request,'userId',p_user,
    'userName',(select data->>'name' from public.mm_rows where coll='users' and id=p_user),
    'at',(extract(epoch from stamp)*1000)::bigint,'by',me->>'name','lines',lines,'amount',p_amount,'memo',p_memo,
    'taxNote','부가세 대상 가능, 세금계산서 대상 (세무사 확인 필요 · 부가세 자동계산/발행 안 함)');
  insert into public.mm_deposit_settlements(id,user_id,by_id,at,items,amount,memo,receipt)
    values(p_request,p_user,me->>'id',stamp,p_items,p_amount,p_memo,res);
  return res;
end $$;

-- KST 기간 조회. 기초잔량은 기간 이전 전 기록, 상세는 기간 해당 기록만 (300/50건 제한 없음).
create or replace function public.mm_deposit_report(p_token text,p_from date,p_to date,p_user text default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare me jsonb:=public.mm_me(p_token); lo timestamptz; hi timestamptz; res jsonb; days integer;
begin
  if coalesce(me->>'role','') not in ('boss','staff') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'INVALID_DATES'; end if;
  lo:=p_from::timestamp at time zone 'Asia/Seoul'; hi:=(p_to+1)::timestamp at time zone 'Asia/Seoul';
  select overdue_days into days from public.mm_deposit_settings where id=true;
  select jsonb_build_object('from',p_from,'to',p_to,'userId',p_user,'overdueDays',days,
    'opening',coalesce((select jsonb_agg(to_jsonb(b)) from (
      select z.user_id,z.menu_id,coalesce(u.data->>'name',z.user_id) user_name,coalesce(m.data->>'name',z.menu_id) menu_name,
        sum(case when z.kind='out' then z.bottles else -z.bottles end) bottles,
        sum(case when z.kind='out' then z.boxes else -z.boxes end) boxes,
        sum(case when z.kind='out' then z.amount else -z.amount end) amount
      from public.mm_deposit z
      left join public.mm_rows u on u.coll='users' and u.id=z.user_id
      left join public.mm_rows m on m.coll='menus' and m.id=z.menu_id
      where z.at<lo and (p_user is null or z.user_id=p_user)
      group by z.user_id,z.menu_id,u.data->>'name',m.data->>'name'
    ) b),'[]'::jsonb),
    'entries',coalesce((select jsonb_agg(to_jsonb(z)||jsonb_build_object('day',(z.at at time zone 'Asia/Seoul')::date,
      'user_name',coalesce(u.data->>'name',z.user_id),'menu_name',coalesce(m.data->>'name',z.menu_id)) order by z.at,z.id)
      from public.mm_deposit z
      left join public.mm_rows u on u.coll='users' and u.id=z.user_id
      left join public.mm_rows m on m.coll='menus' and m.id=z.menu_id
      where z.at>=lo and z.at<hi and (p_user is null or z.user_id=p_user)),'[]'::jsonb),
    'settlements',coalesce((select jsonb_agg(s.receipt order by s.at,s.id) from public.mm_deposit_settlements s
      where s.at>=lo and s.at<hi and (p_user is null or s.user_id=p_user)),'[]'::jsonb)
  ) into res;
  -- FIFO로 소비된 출고는 제외: 회수가 한 번도 없으면 실제 남은 최초 출고를 기준으로 한다.
  with totals as (
    select user_id,menu_id,
      sum(case when kind='out' then bottles else -bottles end) b,
      sum(case when kind='out' then boxes else -boxes end) x,
      coalesce(sum(bottles) filter(where kind<>'out'),0) consumed_b,
      coalesce(sum(boxes) filter(where kind<>'out'),0) consumed_x,
      sum(case when kind='out' then amount else -amount end) amount
    from public.mm_deposit group by user_id,menu_id
  ), outs as (
    select z.*,sum(bottles) over(partition by user_id,menu_id order by at,id) cb,
      sum(boxes) over(partition by user_id,menu_id order by at,id) cx
    from public.mm_deposit z where kind='out'
  ), first_open as (
    select o.user_id,min(o.at) first_out from outs o join totals t using(user_id,menu_id)
    where (t.b>0 and o.bottles>0 and o.cb>t.consumed_b) or (t.x>0 and o.boxes>0 and o.cx>t.consumed_x)
    group by o.user_id
  ), account as (
    select t.user_id,sum(t.b) bottles,sum(t.x) boxes,sum(t.amount) amount,
      (select max(z.at) from public.mm_deposit z where z.user_id=t.user_id and z.kind='in') last_return,
      f.first_out
    from totals t left join first_open f using(user_id)
    group by t.user_id,f.first_out having sum(t.b)>0 or sum(t.x)>0
  )
  select res||jsonb_build_object('accounts',coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object(
    'name',coalesce(u.data->>'name',a.user_id),'anchor',coalesce(a.last_return,a.first_out),
    'ageDays',((now() at time zone 'Asia/Seoul')::date-(coalesce(a.last_return,a.first_out) at time zone 'Asia/Seoul')::date),
    'overdue',((now() at time zone 'Asia/Seoul')::date-(coalesce(a.last_return,a.first_out) at time zone 'Asia/Seoul')::date)>days)
    order by coalesce(a.last_return,a.first_out)), '[]'::jsonb)) into res
  from account a left join public.mm_rows u on u.coll='users' and u.id=a.user_id;
  return res;
end $$;

revoke all on function public.mm_deposit_config(text,integer),public.mm_deposit_report(text,date,date,text),
  public.mm_deposit_settle(text,text,jsonb,numeric,text,text), public.mm_deposit_return(text,text,jsonb,text),
  public.mm_save(text,jsonb,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.mm_deposit_config(text,integer),public.mm_deposit_report(text,date,date,text),
  public.mm_deposit_settle(text,text,jsonb,numeric,text,text), public.mm_deposit_return(text,text,jsonb,text),
  public.mm_save(text,jsonb,jsonb,jsonb) to anon,authenticated;
create or replace function public.mm_deposit_list(p_token text) returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare me jsonb := mm_me(p_token); role text := me->>'role'; uid text := me->>'id';
begin
  if coalesce(role,'') not in ('boss', 'staff', 'customer') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'balances', coalesce((
      select jsonb_agg(jsonb_build_object(
        'userId', b.user_id, 'name', coalesce(u.data->>'name',''), 'phone', coalesce(u.data->>'phone',''),
        'menuId', b.menu_id, 'menuName', coalesce(m.data->>'name', b.menu_id),
        'bottles', b.bottles, 'boxes', b.boxes,
        'bottleDep', greatest(coalesce((m.data->>'bottleDep')::numeric,0),0),
        'boxDep', greatest(coalesce((m.data->>'boxDep')::numeric,0),0),
        'amount', b.amount
      ) order by coalesce(u.data->>'name',''), coalesce(m.data->>'name',''))
      from (
        select user_id, menu_id,
          sum(case when kind='out' then bottles else -bottles end)::bigint as bottles,
          sum(case when kind='out' then boxes else -boxes end)::bigint as boxes,
          sum(case when kind='out' then amount else -amount end) as amount
        from mm_deposit
        where (role in ('boss','staff') or user_id = uid)
        group by user_id, menu_id
        having sum(case when kind='out' then bottles else -bottles end) <> 0
            or sum(case when kind='out' then boxes else -boxes end) <> 0
      ) b
      left join mm_rows u on u.coll='users' and u.id=b.user_id
      left join mm_rows m on m.coll='menus' and m.id=b.menu_id
    ), '[]'),
    'recent', case when role in ('boss','staff') then coalesce((
      select jsonb_agg(to_jsonb(s) order by s.id desc) from (
        select * from mm_deposit where kind='in' order by id desc limit 50
      ) s), '[]') else '[]'::jsonb end
  );
end $$;


revoke all on function public.mm_deposit_list(text) from public,anon,authenticated;
grant execute on function public.mm_deposit_list(text) to anon,authenticated;
notify pgrst,'reload schema';
commit;
