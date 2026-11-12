-- 미래몰 공병·공박스 초과 회수 (deposit2.sql 적용 후 실행, 여러 번 실행해도 안전)
-- 업소 미회수 잔량보다 많이 돌아온 공병·공박스(예: 슈퍼가 소비자에게서 사들인 병)도 보증금을 전액 반환(비과세).
-- 잔량까지는 기존처럼 mm_deposit 'in'으로, 넘는 부분은 mm_deposit_excess에 '초과 회수 (보증금 반환, 비과세)'로 따로 기록.
-- 잔량은 0 아래로 내려가지 않습니다 (기존 잔량 계산은 mm_deposit만 보므로 그대로).
-- 거래처 폐업 정산 이력이 있는 업소의 초과 회수는 사장 확인 대상으로 표시만 합니다 (자동 취소 없음).
begin;

create table if not exists public.mm_deposit_excess (
  id bigserial primary key,
  user_id text not null,
  menu_id text not null,
  bottles integer not null default 0 check (bottles >= 0),
  boxes integer not null default 0 check (boxes >= 0),
  bottle_dep numeric not null default 0,
  box_dep numeric not null default 0,
  amount numeric not null default 0,
  by_id text, by_name text,
  at timestamptz not null default now(),
  memo text not null default '',
  review boolean not null default false,
  reviewed_at timestamptz,
  reviewed_by text
);
create index if not exists mm_deposit_excess_at_idx on public.mm_deposit_excess(at, user_id);
alter table public.mm_deposit_excess enable row level security;
revoke all on public.mm_deposit_excess from public, anon, authenticated;
revoke all on sequence public.mm_deposit_excess_id_seq from public, anon, authenticated;

create or replace function public.mm_deposit_return(p_token text, p_user text, p_items jsonb, p_memo text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare me jsonb := mm_me(p_token); rit jsonb; mid text; m jsonb; rbot int; rbox int; bdep numeric; xdep numeric;
  obot bigint; obox bigint; ib int; ix int; eb int; ex int; lines jsonb := '[]'; total numeric := 0; extotal numeric := 0;
  nid bigint; ids bigint[] := '{}'; xids bigint[] := '{}'; settled boolean; stamp timestamptz := now();
begin
  if coalesce(me->>'role','') not in ('boss', 'staff') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(72611402);
  if exists (select 1 from jsonb_array_elements(coalesce(p_items,'[]')) z group by z->>'menuId' having count(*)>1) then raise exception 'DUPLICATE_ITEM'; end if;
  if not exists (select 1 from mm_rows where coll='users' and id=p_user and data->>'role'='customer') then raise exception 'NO_USER'; end if;
  settled := exists (select 1 from mm_deposit where user_id = p_user and kind = 'settle');
  for rit in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    select id, data into mid, m from mm_rows where coll='menus' and id = rit->>'menuId';
    if mid is null then raise exception 'NO_MENU'; end if;
    bdep := greatest(coalesce((m->>'bottleDep')::numeric, 0), 0);
    xdep := greatest(coalesce((m->>'boxDep')::numeric, 0), 0);
    rbot := least(greatest(coalesce((rit->>'bottles')::int, 0), 0), 1000000);
    rbox := least(greatest(coalesce((rit->>'boxes')::int, 0), 0), 1000000);
    continue when rbot = 0 and rbox = 0;
    select greatest(coalesce(sum(case when kind='out' then bottles else -bottles end),0), 0),
           greatest(coalesce(sum(case when kind='out' then boxes else -boxes end),0), 0)
      into obot, obox from mm_deposit where user_id = p_user and menu_id = mid;
    ib := least(rbot, obot); ix := least(rbox, obox);
    eb := rbot - ib; ex := rbox - ix;
    if ib > 0 or ix > 0 then
      insert into mm_deposit(kind, user_id, menu_id, boxes, bottles, bottle_dep, box_dep, amount, by_id, by_name, at, memo)
        values ('in', p_user, mid, ix, ib, bdep, xdep, ib*bdep + ix*xdep, me->>'id', me->>'name', stamp, left(coalesce(p_memo,''), 200))
        returning id into nid;
      ids := ids || nid;
    end if;
    if eb > 0 or ex > 0 then
      insert into mm_deposit_excess(user_id, menu_id, bottles, boxes, bottle_dep, box_dep, amount, by_id, by_name, at, memo, review)
        values (p_user, mid, eb, ex, bdep, xdep, eb*bdep + ex*xdep, me->>'id', me->>'name', stamp, left(coalesce(p_memo,''), 200), settled)
        returning id into nid;
      xids := xids || nid;
    end if;
    lines := lines || jsonb_build_object('menuId', mid, 'name', m->>'name', 'bottles', rbot, 'boxes', rbox,
      'bottleDep', bdep, 'boxDep', xdep, 'amount', rbot*bdep + rbox*xdep,
      'inBottles', ib, 'inBoxes', ix, 'inAmount', ib*bdep + ix*xdep,
      'excessBottles', eb, 'excessBoxes', ex, 'excessAmount', eb*bdep + ex*xdep);
    total := total + rbot*bdep + rbox*xdep;
    extotal := extotal + eb*bdep + ex*xdep;
  end loop;
  if jsonb_array_length(lines) = 0 then raise exception 'EMPTY'; end if;
  return jsonb_build_object('ok', true, 'amount', total, 'excessAmount', extotal, 'lines', lines, 'ids', to_jsonb(ids), 'excessIds', to_jsonb(xids),
    'settledBefore', settled, 'review', settled and cardinality(xids) > 0,
    'at', (extract(epoch from stamp)*1000)::bigint, 'by', me->>'name',
    'userId', p_user, 'userName', (select data->>'name' from mm_rows where coll='users' and id=p_user));
end $$;

-- 사장 확인 처리
create or replace function public.mm_deposit_excess_review(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me jsonb := public.mm_me(p_token);
begin
  if coalesce(me->>'role','') <> 'boss' then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.mm_deposit_excess set reviewed_at = now(), reviewed_by = me->>'name' where id = p_id and review;
  if not found then raise exception 'NOT_FOUND'; end if;
  return jsonb_build_object('ok', true, 'id', p_id);
end $$;

-- 기간 조회: deposit2 버전 + 'excess'(초과 회수) 목록, 'excessReview'(사장 확인 대기, 기간 무관)
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
    'excess',coalesce((select jsonb_agg(to_jsonb(z)||jsonb_build_object('kind','excess','day',(z.at at time zone 'Asia/Seoul')::date,
      'user_name',coalesce(u.data->>'name',z.user_id),'menu_name',coalesce(m.data->>'name',z.menu_id)) order by z.at,z.id)
      from public.mm_deposit_excess z
      left join public.mm_rows u on u.coll='users' and u.id=z.user_id
      left join public.mm_rows m on m.coll='menus' and m.id=z.menu_id
      where z.at>=lo and z.at<hi and (p_user is null or z.user_id=p_user)),'[]'::jsonb),
    'excessReview',coalesce((select jsonb_agg(to_jsonb(z)||jsonb_build_object('day',(z.at at time zone 'Asia/Seoul')::date,
      'user_name',coalesce(u.data->>'name',z.user_id),'menu_name',coalesce(m.data->>'name',z.menu_id)) order by z.at,z.id)
      from public.mm_deposit_excess z
      left join public.mm_rows u on u.coll='users' and u.id=z.user_id
      left join public.mm_rows m on m.coll='menus' and m.id=z.menu_id
      where z.review and z.reviewed_at is null),'[]'::jsonb),
    'settlements',coalesce((select jsonb_agg(s.receipt order by s.at,s.id) from public.mm_deposit_settlements s
      where s.at>=lo and s.at<hi and (p_user is null or s.user_id=p_user)),'[]'::jsonb)
  ) into res;
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

revoke all on function public.mm_deposit_return(text,text,jsonb,text), public.mm_deposit_excess_review(text,bigint),
  public.mm_deposit_report(text,date,date,text) from public, anon, authenticated;
grant execute on function public.mm_deposit_return(text,text,jsonb,text), public.mm_deposit_excess_review(text,bigint),
  public.mm_deposit_report(text,date,date,text) to anon, authenticated;
notify pgrst, 'reload schema';
commit;
