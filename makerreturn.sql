-- 미래몰 제조사 반납 (bottleexcess.sql 적용 후 실행, 여러 번 실행해도 안전)
-- 회수한 공병·공박스를 제조사에 넘기고 보증금을 돌려받는 기록. 전부 비과세 보증금(부가세 없음).
-- 직원·사장만 사용 (손님 거부). 사장 승인 없음: 직원·사장 기입 즉시 반영. 제조사 목록·품목 연결 수정만 사장.
-- 보증금 입금 확인(미수령/수령)은 선택 표시이며 아무것도 막지 않음.
-- 창고 보유 = 업소에서 회수(mm_deposit 'in' + mm_deposit_excess 초과 회수) − 제조사 반납(취소 제외).
begin;

do $$ begin
  if to_regclass('public.mm_deposit_excess') is null then
    raise exception 'bottleexcess.sql을 먼저 적용해 주세요 (mm_deposit_excess 없음)';
  end if;
end $$;

create table if not exists public.mm_makers (
  id text primary key default gen_random_uuid()::text,
  name text not null,
  memo text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text
);
create unique index if not exists mm_makers_name_uq on public.mm_makers (lower(name));

create table if not exists public.mm_maker_menus (
  menu_id text primary key,
  maker_id text not null references public.mm_makers(id),
  updated_at timestamptz not null default now(),
  updated_by text
);

create table if not exists public.mm_maker_returns (
  id bigserial primary key,
  request text unique,
  day date not null,
  maker_id text not null references public.mm_makers(id),
  maker_name text not null default '',
  status text not null default 'pending' check (status in ('pending','received','void')),
  bottles integer not null default 0,
  boxes integer not null default 0,
  amount numeric not null default 0,
  memo text not null default '',
  over_held boolean not null default false,
  by_id text, by_name text,
  at timestamptz not null default now(),
  decided_at timestamptz, decided_by text, decide_memo text not null default ''
);
create index if not exists mm_maker_returns_day_idx on public.mm_maker_returns(day, maker_id);
create index if not exists mm_maker_returns_status_idx on public.mm_maker_returns(status);

create table if not exists public.mm_maker_return_lines (
  id bigserial primary key,
  return_id bigint not null references public.mm_maker_returns(id) on delete cascade,
  menu_id text not null,
  menu_name text not null default '',
  bottles integer not null default 0 check (bottles >= 0),
  boxes integer not null default 0 check (boxes >= 0),
  bottle_dep numeric not null default 0 check (bottle_dep >= 0),
  box_dep numeric not null default 0 check (box_dep >= 0),
  amount numeric not null default 0
);
create index if not exists mm_maker_return_lines_ret_idx on public.mm_maker_return_lines(return_id);
create index if not exists mm_maker_return_lines_menu_idx on public.mm_maker_return_lines(menu_id);

alter table public.mm_makers enable row level security;
alter table public.mm_maker_menus enable row level security;
alter table public.mm_maker_returns enable row level security;
alter table public.mm_maker_return_lines enable row level security;
revoke all on public.mm_makers, public.mm_maker_menus, public.mm_maker_returns, public.mm_maker_return_lines from public, anon, authenticated;
revoke all on sequence public.mm_maker_returns_id_seq, public.mm_maker_return_lines_id_seq from public, anon, authenticated;

-- 내부용: p_day 이전(미포함)까지 품목별 창고 수불. p_day null이면 전체(현재).
create or replace function public.mm_maker_held(p_day date)
returns table(menu_id text, in_b bigint, in_x bigint, ex_b bigint, ex_x bigint, ret_b bigint, ret_x bigint)
language sql stable security definer set search_path = '' as $$
  with lim as (select case when p_day is null then 'infinity'::timestamptz else p_day::timestamp at time zone 'Asia/Seoul' end lo),
  ev as (
    select z.menu_id, z.bottles::bigint ib, z.boxes::bigint ix, 0::bigint eb, 0::bigint ex, 0::bigint rb, 0::bigint rx
      from public.mm_deposit z, lim where z.kind = 'in' and z.at < lim.lo
    union all
    select z.menu_id, 0, 0, z.bottles, z.boxes, 0, 0 from public.mm_deposit_excess z, lim where z.at < lim.lo
    union all
    select l.menu_id, 0, 0, 0, 0, l.bottles, l.boxes
      from public.mm_maker_return_lines l join public.mm_maker_returns r on r.id = l.return_id
      where r.status <> 'void' and (p_day is null or r.day < p_day)
  )
  select menu_id, sum(ib)::bigint, sum(ix)::bigint, sum(eb)::bigint, sum(ex)::bigint, sum(rb)::bigint, sum(rx)::bigint
  from ev group by menu_id
$$;

-- 내부용: 반납 기록 1건 JSON
create or replace function public.mm_maker_return_json(p_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(r) || jsonb_build_object(
    'atMs', (extract(epoch from r.at)*1000)::bigint,
    'decidedMs', case when r.decided_at is null then null else (extract(epoch from r.decided_at)*1000)::bigint end,
    'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.id) from public.mm_maker_return_lines l where l.return_id = r.id), '[]'::jsonb))
  from public.mm_maker_returns r where r.id = p_id
$$;

-- 내부용: 현재 창고 보유 (품목별)
create or replace function public.mm_maker_held_json()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('menu_id', h.menu_id, 'menu_name', coalesce(m.data->>'name', h.menu_id),
    'maker_id', mm.maker_id, 'maker_name', mk.name, 'inBottles', h.in_b, 'inBoxes', h.in_x, 'exBottles', h.ex_b, 'exBoxes', h.ex_x,
    'retBottles', h.ret_b, 'retBoxes', h.ret_x, 'bottles', h.in_b + h.ex_b - h.ret_b, 'boxes', h.in_x + h.ex_x - h.ret_x)
    order by coalesce(m.data->>'name', h.menu_id)), '[]'::jsonb)
  from public.mm_maker_held(null) h
  left join public.mm_rows m on m.coll = 'menus' and m.id = h.menu_id
  left join public.mm_maker_menus mm on mm.menu_id = h.menu_id
  left join public.mm_makers mk on mk.id = mm.maker_id
$$;

create or replace function public.mm_maker_list(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare me jsonb := public.mm_me(p_token);
begin
  if coalesce(me->>'role','') not in ('boss','staff') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'makers', coalesce((select jsonb_agg(to_jsonb(k) order by k.active desc, k.name) from public.mm_makers k), '[]'::jsonb),
    'map', coalesce((select jsonb_object_agg(menu_id, maker_id) from public.mm_maker_menus), '{}'::jsonb),
    'held', public.mm_maker_held_json(),
    'pending', coalesce((select jsonb_agg(public.mm_maker_return_json(r.id) order by r.day, r.id) from public.mm_maker_returns r where r.status = 'pending'), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(public.mm_maker_return_json(x.id) order by x.at desc, x.id desc) from
      (select id, at from public.mm_maker_returns where status <> 'pending' order by at desc, id desc limit 30) x), '[]'::jsonb));
end $$;

create or replace function public.mm_maker_save(p_token text, p_id text, p_name text, p_memo text, p_active boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me jsonb := public.mm_me(p_token); nm text := btrim(coalesce(p_name,'')); rid text;
begin
  if coalesce(me->>'role','') <> 'boss' then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if nm = '' or length(nm) > 100 then raise exception 'BAD_NAME'; end if;
  if exists (select 1 from public.mm_makers where lower(name) = lower(nm) and id is distinct from nullif(p_id,'')) then raise exception 'DUP_NAME'; end if;
  if nullif(p_id,'') is null then
    insert into public.mm_makers(name, memo, active, updated_by) values (nm, left(coalesce(p_memo,''),500), coalesce(p_active,true), me->>'name') returning id into rid;
  else
    update public.mm_makers set name = nm, memo = left(coalesce(p_memo,''),500), active = coalesce(p_active,true), updated_at = now(), updated_by = me->>'name'
      where id = p_id returning id into rid;
    if rid is null then raise exception 'NOT_FOUND'; end if;
  end if;
  return (select to_jsonb(k) from public.mm_makers k where k.id = rid);
end $$;

create or replace function public.mm_maker_map(p_token text, p_menu text, p_maker text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me jsonb := public.mm_me(p_token);
begin
  if coalesce(me->>'role','') <> 'boss' then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.mm_rows where coll='menus' and id=p_menu) then raise exception 'NO_MENU'; end if;
  if nullif(p_maker,'') is null then
    delete from public.mm_maker_menus where menu_id = p_menu;
  else
    if not exists (select 1 from public.mm_makers where id = p_maker) then raise exception 'NO_MAKER'; end if;
    insert into public.mm_maker_menus(menu_id, maker_id, updated_by) values (p_menu, p_maker, me->>'name')
      on conflict (menu_id) do update set maker_id = excluded.maker_id, updated_at = now(), updated_by = excluded.updated_by;
  end if;
  return jsonb_build_object('ok', true, 'menu', p_menu, 'maker', nullif(p_maker,''));
end $$;

-- 반납 기입 (직원·사장). 단가는 품목 보증금 설정이 기본, 건별로 바꿀 수 있음. 보유량 초과도 저장(over_held 표시).
create or replace function public.mm_maker_return_add(p_token text, p_request text, p_day date, p_maker text, p_items jsonb, p_memo text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me jsonb := public.mm_me(p_token); rid bigint; k record; it jsonb; m record; b int; x int; bd numeric; xd numeric;
  tb int := 0; tx int := 0; ta numeric := 0; over boolean := false; hb bigint; hx bigint; overs jsonb := '[]';
begin
  if coalesce(me->>'role','') not in ('boss','staff') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if nullif(p_request,'') is not null then
    select id into rid from public.mm_maker_returns where request = p_request;
    if rid is not null then return public.mm_maker_return_json(rid) || jsonb_build_object('replay', true); end if;
  end if;
  if p_day is null or p_day < date '2000-01-01' or p_day > (now() at time zone 'Asia/Seoul')::date + 1 then raise exception 'BAD_DAY'; end if;
  select * into k from public.mm_makers where id = p_maker;
  if k.id is null then raise exception 'NO_MAKER'; end if;
  if jsonb_typeof(coalesce(p_items,'null')) <> 'array' then raise exception 'EMPTY'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) z group by z->>'menuId' having count(*) > 1) then raise exception 'DUPLICATE_ITEM'; end if;
  perform pg_advisory_xact_lock(72611403);
  insert into public.mm_maker_returns(request, day, maker_id, maker_name, memo, by_id, by_name)
    values (nullif(p_request,''), p_day, k.id, k.name, left(coalesce(p_memo,''),500), me->>'id', me->>'name') returning id into rid;
  for it in select * from jsonb_array_elements(p_items) loop
    select id, data into m from public.mm_rows where coll='menus' and id = it->>'menuId';
    if m.id is null then raise exception 'NO_MENU'; end if;
    b := coalesce((it->>'bottles')::int, 0); x := coalesce((it->>'boxes')::int, 0);
    if b < 0 or x < 0 or b > 1000000 or x > 1000000 then raise exception 'BAD_QTY'; end if;
    continue when b = 0 and x = 0;
    bd := coalesce(nullif(it->>'bottleDep','')::numeric, (m.data->>'bottleDep')::numeric, 0);
    xd := coalesce(nullif(it->>'boxDep','')::numeric, (m.data->>'boxDep')::numeric, 0);
    if bd < 0 or xd < 0 or bd > 1000000 or xd > 1000000 then raise exception 'BAD_DEP'; end if;
    select coalesce(h.in_b + h.ex_b - h.ret_b, 0), coalesce(h.in_x + h.ex_x - h.ret_x, 0) into hb, hx
      from public.mm_maker_held(null) h where h.menu_id = m.id;
    hb := coalesce(hb, 0); hx := coalesce(hx, 0);
    if b > hb or x > hx then over := true;
      overs := overs || jsonb_build_object('menuId', m.id, 'name', m.data->>'name', 'bottles', b, 'boxes', x, 'heldBottles', hb, 'heldBoxes', hx); end if;
    insert into public.mm_maker_return_lines(return_id, menu_id, menu_name, bottles, boxes, bottle_dep, box_dep, amount)
      values (rid, m.id, coalesce(m.data->>'name', m.id), b, x, bd, xd, b*bd + x*xd);
    tb := tb + b; tx := tx + x; ta := ta + b*bd + x*xd;
  end loop;
  if tb = 0 and tx = 0 then raise exception 'EMPTY'; end if;
  update public.mm_maker_returns set bottles = tb, boxes = tx, amount = ta, over_held = over where id = rid;
  return public.mm_maker_return_json(rid) || jsonb_build_object('over', overs);
end $$;

-- 보증금 입금 확인 표시 (선택 사항, 직원·사장 모두). 승인 절차 아님: 반납 기록은 저장 즉시 창고 보유에 반영됨.
-- receive: 미수령→수령, unreceive: 수령→미수령(잘못 표시 되돌리기), void: 잘못 기입한 기록 취소(사유 기록, 보유량 원복)
create or replace function public.mm_maker_return_decide(p_token text, p_id bigint, p_action text, p_memo text default '')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me jsonb := public.mm_me(p_token);
begin
  if coalesce(me->>'role','') not in ('boss','staff') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_action = 'receive' then
    update public.mm_maker_returns set status = 'received', decided_at = now(), decided_by = me->>'name', decide_memo = left(coalesce(p_memo,''),500)
      where id = p_id and status = 'pending';
  elsif p_action = 'unreceive' then
    update public.mm_maker_returns set status = 'pending', decided_at = null, decided_by = null, decide_memo = left(coalesce(p_memo,''),500)
      where id = p_id and status = 'received';
  elsif p_action = 'void' then
    if btrim(coalesce(p_memo,'')) = '' then raise exception 'NEED_REASON'; end if;
    update public.mm_maker_returns set status = 'void', decided_at = now(), decided_by = me->>'name', decide_memo = left(p_memo,500)
      where id = p_id and status <> 'void';
  else raise exception 'BAD_ACTION'; end if;
  if not found then raise exception 'NOT_PENDING'; end if;
  return public.mm_maker_return_json(p_id);
end $$;

-- 기간 조회 (반납일 기준, KST). 창고 수불: 기초 + 회수 + 초과 회수 − 반납 = 기말
create or replace function public.mm_maker_report(p_token text, p_from date, p_to date, p_maker text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare me jsonb := public.mm_me(p_token);
begin
  if coalesce(me->>'role','') not in ('boss','staff') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'INVALID_DATES'; end if;
  return jsonb_build_object('from', p_from, 'to', p_to, 'makerId', nullif(p_maker,''),
    'returns', coalesce((select jsonb_agg(public.mm_maker_return_json(r.id) order by r.day, r.id) from public.mm_maker_returns r
      where r.day between p_from and p_to and (nullif(p_maker,'') is null or r.maker_id = p_maker)), '[]'::jsonb),
    'warehouse', coalesce((select jsonb_agg(jsonb_build_object('menu_id', a.menu_id, 'menu_name', coalesce(m.data->>'name', a.menu_id), 'maker_id', mm.maker_id, 'maker_name', mk.name,
        'openBottles', coalesce(o.in_b + o.ex_b - o.ret_b, 0), 'openBoxes', coalesce(o.in_x + o.ex_x - o.ret_x, 0),
        'inBottles', a.in_b - coalesce(o.in_b,0), 'inBoxes', a.in_x - coalesce(o.in_x,0),
        'exBottles', a.ex_b - coalesce(o.ex_b,0), 'exBoxes', a.ex_x - coalesce(o.ex_x,0),
        'retBottles', a.ret_b - coalesce(o.ret_b,0), 'retBoxes', a.ret_x - coalesce(o.ret_x,0),
        'bottles', a.in_b + a.ex_b - a.ret_b, 'boxes', a.in_x + a.ex_x - a.ret_x) order by coalesce(m.data->>'name', a.menu_id))
      from public.mm_maker_held(p_to + 1) a
      left join public.mm_maker_held(p_from) o on o.menu_id = a.menu_id
      left join public.mm_rows m on m.coll = 'menus' and m.id = a.menu_id
      left join public.mm_maker_menus mm on mm.menu_id = a.menu_id
      left join public.mm_makers mk on mk.id = mm.maker_id), '[]'::jsonb));
end $$;

revoke all on function public.mm_maker_held(date), public.mm_maker_return_json(bigint), public.mm_maker_held_json() from public, anon, authenticated;
revoke all on function public.mm_maker_list(text), public.mm_maker_save(text,text,text,text,boolean), public.mm_maker_map(text,text,text),
  public.mm_maker_return_add(text,text,date,text,jsonb,text), public.mm_maker_return_decide(text,bigint,text,text),
  public.mm_maker_report(text,date,date,text) from public, anon, authenticated;
grant execute on function public.mm_maker_list(text), public.mm_maker_save(text,text,text,text,boolean), public.mm_maker_map(text,text,text),
  public.mm_maker_return_add(text,text,date,text,jsonb,text), public.mm_maker_return_decide(text,bigint,text,text),
  public.mm_maker_report(text,date,date,text) to anon, authenticated;
notify pgrst, 'reload schema';
commit;
