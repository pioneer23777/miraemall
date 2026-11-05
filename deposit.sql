-- 미래몰 공병·공박스 보증금/회수 (stock2.sql mm_save 기준, 여러 번 실행해도 안전)
create table if not exists public.mm_deposit (
  id bigserial primary key,
  kind text not null check (kind in ('out', 'in')),
  user_id text not null,
  menu_id text not null,
  order_id text,
  boxes integer not null default 0 check (boxes >= 0),
  bottles integer not null default 0 check (bottles >= 0),
  bottle_dep numeric not null default 0,
  box_dep numeric not null default 0,
  amount numeric not null default 0,
  by_id text, by_name text,
  at timestamptz not null default now(),
  memo text not null default ''
);
create index if not exists mm_deposit_user_idx on public.mm_deposit(user_id, menu_id);
create index if not exists mm_deposit_order_idx on public.mm_deposit(order_id);
alter table public.mm_deposit enable row level security;
revoke all on public.mm_deposit from anon, authenticated;
revoke all on sequence public.mm_deposit_id_seq from anon, authenticated;

create or replace function public.mm_save(p_token text, p_rows jsonb, p_kv jsonb, p_dels jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare me jsonb := mm_me(p_token); role text := me->>'role'; uid text := me->>'id';
  r jsonb; c text; i text; d jsonb; ex jsonb; skipped int := 0; it jsonb; m jsonb; u jsonb;
  items jsonb; mid text; ev jsonb; et text; en text; eb text; q int; supply numeric; earn numeric; vat numeric; bal numeric; used numeric;
  dep numeric; ret jsonb; rit jsonb; rbot int; rbox int; ramt numeric; obot bigint; obox bigint;
  bpp int; bdep numeric; xdep numeric; catn text; mrow record;
begin
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
          insert into mm_deposit(kind, user_id, menu_id, order_id, boxes, bottles, bottle_dep, box_dep, amount, by_id, by_name, memo)
            values ('in', d->>'userId', rit->>'menuId', i, rbox, rbot,
              coalesce((rit->>'bottleDep')::numeric,0), coalesce((rit->>'boxDep')::numeric,0),
              coalesce((rit->>'amount')::numeric, rbot*coalesce((rit->>'bottleDep')::numeric,0)+rbox*coalesce((rit->>'boxDep')::numeric,0)),
              me->>'id', me->>'name', '주문회수');
        end loop;
      elsif d->>'status' is distinct from '완료' then
        d := d - 'doneAt';
        if ex->>'status' = '완료' then delete from mm_deposit where order_id = i; end if;
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

revoke all on function public.mm_me(text), public.mm_login(text, text), public.mm_logout(text), public.mm_signup(text, text, text),
  public.mm_public(), public.mm_fetch(text), public.mm_save(text, jsonb, jsonb, jsonb), public.mm_ping_trg() from public, anon, authenticated;
grant execute on function public.mm_login(text, text), public.mm_logout(text), public.mm_signup(text, text, text),
  public.mm_public(), public.mm_fetch(text), public.mm_save(text, jsonb, jsonb, jsonb) to anon, authenticated;



-- 업소별 미회수 잔량 (사장/직원: 전체, 고객: 본인)
create or replace function public.mm_deposit_list(p_token text) returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare me jsonb := mm_me(p_token); role text := me->>'role'; uid text := me->>'id';
begin
  if role not in ('boss', 'staff', 'customer') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'balances', coalesce((
      select jsonb_agg(jsonb_build_object(
        'userId', b.user_id, 'name', coalesce(u.data->>'name',''), 'phone', coalesce(u.data->>'phone',''),
        'menuId', b.menu_id, 'menuName', coalesce(m.data->>'name', b.menu_id),
        'bottles', b.bottles, 'boxes', b.boxes,
        'bottleDep', greatest(coalesce((m.data->>'bottleDep')::numeric,0),0),
        'boxDep', greatest(coalesce((m.data->>'boxDep')::numeric,0),0),
        'amount', b.bottles * greatest(coalesce((m.data->>'bottleDep')::numeric,0),0)
               + b.boxes * greatest(coalesce((m.data->>'boxDep')::numeric,0),0)
      ) order by coalesce(u.data->>'name',''), coalesce(m.data->>'name',''))
      from (
        select user_id, menu_id,
          sum(case when kind='out' then bottles else -bottles end)::bigint as bottles,
          sum(case when kind='out' then boxes else -boxes end)::bigint as boxes
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

-- 직원/사장 수동 회수 기입 (주문 없이)
create or replace function public.mm_deposit_return(p_token text, p_user text, p_items jsonb, p_memo text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare me jsonb := mm_me(p_token); rit jsonb; mid text; m jsonb; rbot int; rbox int; bdep numeric; xdep numeric;
  obot bigint; obox bigint; lines jsonb := '[]'; total numeric := 0; nid bigint; ids bigint[] := '{}';
begin
  if me->>'role' not in ('boss', 'staff') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
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

revoke all on function public.mm_save(text, jsonb, jsonb, jsonb), public.mm_deposit_list(text), public.mm_deposit_return(text, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.mm_save(text, jsonb, jsonb, jsonb), public.mm_deposit_list(text), public.mm_deposit_return(text, text, jsonb, text) to anon, authenticated;
