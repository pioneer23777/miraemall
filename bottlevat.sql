-- 미래몰 공병·공박스 부가세 처리 (deposit2.sql 적용 후 실행, 여러 번 실행해도 안전)
-- 부가가치세법 시행령 제61조제2항, 부가기본통칙 13-48-5 ①: 반환조건부 공병·공박스 대금은 공급가액 제외(부가세 없음), 회수 환급도 부가세 없음.
-- 부가기본통칙 13-48-5 ②: 미회수로 변상금 처리하면 과세 공급. 변상금액을 부가세 포함 공급대가로 보고
--   공급가액 = round(금액*10/11), 부가세 = 금액 - 공급가액.
-- mm_deposit_settle 의 인자·권한은 그대로 두고, 영수증(receipt)에 공급가액·부가세·증빙을 추가합니다.
begin;

-- 장기 미회수 기준 기본값 60일 → 30일 (사장이 바꾼 값이 60이 아니면 유지)
alter table public.mm_deposit_settings alter column overdue_days set default 30;
update public.mm_deposit_settings set overdue_days = 30 where id = true and overdue_days = 60;

alter table public.mm_deposit_settlements add column if not exists supply numeric;
alter table public.mm_deposit_settlements add column if not exists vat numeric;
alter table public.mm_deposit_settlements add column if not exists evidence jsonb;

-- 업소 증빙: 최근 주문에서 고른 증빙(현금영수증/세금계산서) 우선, 없으면 가입 사업자번호로 세금계산서
create or replace function public.mm_user_evidence(p_user text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare ev jsonb; u jsonb; b text;
begin
  select o.data->'evidence' into ev from public.mm_rows o
   where o.coll = 'orders' and o.data->>'userId' = p_user and o.data->'evidence'->>'type' in ('cash', 'tax')
   order by nullif(o.data->>'at', '')::bigint desc nulls last limit 1;
  if ev is not null then return ev || jsonb_build_object('source', 'order'); end if;
  select data into u from public.mm_rows where coll = 'users' and id = p_user;
  b := regexp_replace(coalesce(u->>'bizNo', u->'taxInfo'->>'bizNo', ''), '\D', '', 'g');
  if length(b) = 10 then return jsonb_build_object('type', 'tax', 'bizNo', b, 'source', 'signup'); end if;
  return jsonb_build_object('type', 'none');
end $$;

-- 기존 정산 기록 보정 (공급가액·부가세가 없는 것만)
update public.mm_deposit_settlements s set
  supply = round(s.amount * 10 / 11),
  vat = s.amount - round(s.amount * 10 / 11),
  evidence = coalesce(s.evidence, public.mm_user_evidence(s.user_id))
 where s.supply is null or s.vat is null;
update public.mm_deposit_settlements s set
  receipt = s.receipt || jsonb_build_object('supply', s.supply, 'vat', s.vat, 'taxable', true,
    'evidence', s.evidence,
    'taxNote', '과세 매출 (부가기본통칙 13-48-5 ②) · 변상금액은 부가세 포함 공급대가')
 where not (s.receipt ? 'vat') or not (s.receipt ? 'taxable');

create or replace function public.mm_deposit_settle(p_token text, p_user text, p_items jsonb, p_amount numeric, p_memo text, p_request text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare me jsonb:=public.mm_me(p_token); z jsonb; m jsonb; b bigint; x bigint; ob bigint; ox bigint;
  bd numeric; xd numeric; nid bigint; lines jsonb:='[]'; res jsonb; prev public.mm_deposit_settlements%rowtype;
  stamp timestamptz:=clock_timestamp(); sup numeric; tax numeric; ev jsonb;
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
  sup := round(p_amount * 10 / 11);
  tax := p_amount - sup;
  ev := public.mm_user_evidence(p_user);
  res:=jsonb_build_object('ok',true,'id',p_request,'userId',p_user,
    'userName',(select data->>'name' from public.mm_rows where coll='users' and id=p_user),
    'at',(extract(epoch from stamp)*1000)::bigint,'by',me->>'name','lines',lines,'amount',p_amount,'memo',p_memo,
    'supply',sup,'vat',tax,'taxable',true,'evidence',ev,
    'taxNote','과세 매출 (부가기본통칙 13-48-5 ②) · 변상금액은 부가세 포함 공급대가');
  insert into public.mm_deposit_settlements(id,user_id,by_id,at,items,amount,memo,receipt,supply,vat,evidence)
    values(p_request,p_user,me->>'id',stamp,p_items,p_amount,p_memo,res,sup,tax,ev);
  return res;
end $$;

revoke all on function public.mm_user_evidence(text) from public, anon, authenticated;
revoke all on function public.mm_deposit_settle(text,text,jsonb,numeric,text,text) from public, anon, authenticated;
grant execute on function public.mm_deposit_settle(text,text,jsonb,numeric,text,text) to anon, authenticated;
notify pgrst, 'reload schema';
commit;
