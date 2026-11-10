-- 미래몰 가입 승인 유지, 사업자번호, 비밀번호 5회 잠금
-- Supabase SQL Editor에서 실행. 여러 번 실행해도 안전.
-- 기존 계정·세션·mm_save/mm_fetch 와 호환. 사용자 정보는 mm_rows.data JSONB에 저장.

-- 사업자등록번호(10자리) 공식 검증: 가중치 1,3,7,1,3,7,1,3,5
-- 합계 + floor(9번째자리*5/10) 를 10으로 나눈 뒤 (10-나머지)%10 이 검증숫자
create or replace function public.mm_valid_bizno(p text) returns boolean
language plpgsql immutable parallel safe set search_path = public as $$
declare
  d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  w int[] := array[1, 3, 7, 1, 3, 7, 1, 3, 5];
  s int := 0;
  i int;
begin
  if length(d) <> 10 then return false; end if;
  for i in 1..9 loop
    s := s + substr(d, i, 1)::int * w[i];
  end loop;
  s := s + (substr(d, 9, 1)::int * 5) / 10;
  return ((10 - (s % 10)) % 10) = substr(d, 10, 1)::int;
end $$;

-- 잠긴 고객·직원은 기존 세션으로도 데이터를 못 읽게 함. 사장 15분 잠금은 기존 세션 유지.
create or replace function public.mm_me(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare u jsonb;
begin
  select r.data into u from mm_sessions s join mm_rows r on r.coll = 'users' and r.id = s.user_id
   where s.token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
     and s.expires_at > now()
     and r.data->>'status' = 'active'
     and coalesce(r.data->>'locked', 'false') <> 'true';
  if u is null then raise exception 'AUTH' using errcode = '28000'; end if;
  return u - 'pwh';
end $$;

create or replace function public.mm_login(p_phone text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  r record;
  t text;
  fc int;
  until_ms bigint;
  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  select id, data into r from mm_rows
   where coll = 'users' and data->>'phone' = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')
   limit 1 for update;
  if r.id is null then
    return jsonb_build_object('error', 'bad');
  end if;

  -- 이미 잠긴 계정: 비밀번호가 맞아도 들어가지 못함
  if r.data->>'role' = 'boss' then
    until_ms := nullif(r.data->>'lockUntil', '')::bigint;
    if until_ms is not null and until_ms > now_ms then
      return jsonb_build_object('error', 'locked', 'remain', 0, 'until', until_ms);
    end if;
  elsif coalesce(r.data->>'locked', 'false') = 'true' then
    return jsonb_build_object('error', 'locked', 'remain', 0);
  end if;

  if r.data->>'pwh' is null or crypt(coalesce(p_pw, ''), r.data->>'pwh') <> r.data->>'pwh' then
    fc := coalesce(nullif(r.data->>'failCount', '')::int, 0) + 1;
    if fc >= 5 then
      if r.data->>'role' = 'boss' then
        until_ms := now_ms + 15 * 60 * 1000;
        update mm_rows set
          data = (data - 'lockedAt') || jsonb_build_object('failCount', 0, 'locked', false, 'lockUntil', until_ms),
          updated_at = now()
         where coll = 'users' and id = r.id;
        return jsonb_build_object('error', 'locked', 'remain', 0, 'until', until_ms);
      end if;
      update mm_rows set
        data = (data - 'lockUntil') || jsonb_build_object(
          'failCount', 0, 'locked', true, 'lockedAt', now_ms),
        updated_at = now()
       where coll = 'users' and id = r.id;
      delete from mm_sessions where user_id = r.id;
      return jsonb_build_object('error', 'locked', 'remain', 0);
    end if;
    update mm_rows set
      data = data || jsonb_build_object('failCount', fc),
      updated_at = now()
     where coll = 'users' and id = r.id;
    return jsonb_build_object('error', 'bad', 'remain', 5 - fc);
  end if;

  -- 비밀번호가 맞으면 실패 횟수·한시 잠금을 지움 (승인 대기/거절이어도 카운터는 리셋)
  update mm_rows set
    data = (data - 'lockedAt' - 'lockUntil') || jsonb_build_object('failCount', 0, 'locked', false),
    updated_at = now()
   where coll = 'users' and id = r.id
   returning data into r.data;

  if r.data->>'status' <> 'active' then
    return jsonb_build_object('error', r.data->>'status');
  end if;

  delete from mm_sessions where expires_at < now();
  t := encode(gen_random_bytes(24), 'hex');
  insert into mm_sessions values (encode(digest(t, 'sha256'), 'hex'), r.id, now() + interval '30 days');
  return jsonb_build_object('token', t, 'user', r.data - 'pwh');
end $$;

-- 기존 3인자 가입은 유지(옛 앱 호환). 새 앱은 아래 4인자 함수를 씀.
create or replace function public.mm_signup(p_name text, p_phone text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare p text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'); i text := 'u' || substr(md5(random()::text), 1, 8);
begin
  if coalesce(trim(p_name), '') = '' or length(p) < 10 or length(coalesce(p_pw, '')) < 4 then return jsonb_build_object('error', 'invalid'); end if;
  if exists (select 1 from mm_rows where coll = 'users' and data->>'phone' = p) then return jsonb_build_object('error', 'dup'); end if;
  insert into mm_rows(coll, id, pos, data) values ('users', i, (select coalesce(max(pos), 0) + 1 from mm_rows where coll = 'users'),
    jsonb_build_object('id', i, 'role', 'customer', 'name', left(trim(p_name), 40), 'phone', p, 'status', 'pending',
      'failCount', 0, 'locked', false, 'pwh', crypt(p_pw, gen_salt('bf', 8))));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.mm_signup(p_name text, p_phone text, p_pw text, p_bizno text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  p text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  b text := regexp_replace(coalesce(p_bizno, ''), '\D', '', 'g');
  i text := 'u' || substr(md5(random()::text), 1, 8);
begin
  if coalesce(trim(p_name), '') = '' or length(p) < 10 or length(coalesce(p_pw, '')) < 4 then
    return jsonb_build_object('error', 'invalid');
  end if;
  if not mm_valid_bizno(b) then return jsonb_build_object('error', 'bizno'); end if;
  if exists (select 1 from mm_rows where coll = 'users' and data->>'phone' = p) then
    return jsonb_build_object('error', 'dup');
  end if;
  insert into mm_rows(coll, id, pos, data) values (
    'users', i, (select coalesce(max(pos), 0) + 1 from mm_rows where coll = 'users'),
    jsonb_build_object(
      'id', i, 'role', 'customer', 'name', left(trim(p_name), 40), 'phone', p,
      'status', 'pending', 'bizNo', b, 'taxInfo', jsonb_build_object('bizNo', b),
      'failCount', 0, 'locked', false, 'pwh', crypt(p_pw, gen_salt('bf', 8))));
  return jsonb_build_object('ok', true);
end $$;

-- 고객은 사장·직원이 해제. 직원 계정은 사장만 해제. 사장 본인(15분)은 대상 아님.
create or replace function public.mm_unlock(p_token text, p_user text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare me jsonb := mm_me(p_token); role text := me->>'role'; t jsonb;
begin
  select data into t from mm_rows where coll = 'users' and id = p_user for update;
  if t is null then return jsonb_build_object('error', 'none'); end if;
  if t->>'role' = 'boss' then return jsonb_build_object('error', 'forbidden'); end if;
  if role = 'boss' then
    null;
  elsif role = 'staff' and t->>'role' = 'customer' then
    null;
  else
    return jsonb_build_object('error', 'forbidden');
  end if;
  update mm_rows set
    data = (data - 'lockedAt' - 'lockUntil') || jsonb_build_object('failCount', 0, 'locked', false),
    updated_at = now()
   where coll = 'users' and id = p_user;
  return jsonb_build_object('ok', true);
end $$;

-- 비밀번호 초기화 때도 잠금을 풀어 임시 비밀번호로 바로 들어올 수 있게 함
create or replace function public.mm_reset_password(p_token text, p_user text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare me jsonb := mm_me(p_token); role text := me->>'role'; t jsonb; tmp text;
begin
  select data into t from mm_rows where coll = 'users' and id = p_user for update;
  if t is null then return jsonb_build_object('error', 'none'); end if;
  if not (role = 'boss' and p_user <> me->>'id' or role = 'staff' and t->>'role' = 'customer') then
    return jsonb_build_object('error', 'forbidden');
  end if;
  tmp := lpad((floor(random() * 1000000))::int::text, 6, '0');
  update mm_rows set
    data = (data - 'lockedAt' - 'lockUntil') || jsonb_build_object(
      'pwh', crypt(tmp, gen_salt('bf', 8)), 'failCount', 0, 'locked', false)
   where coll = 'users' and id = p_user;
  delete from mm_sessions where user_id = p_user;
  return jsonb_build_object('ok', true, 'temp', tmp);
end $$;

-- 가입 승인(pending → active) 시 잠금·실패횟수도 함께 지움
create or replace function public.mm_users_clear_lock_on_active() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.coll = 'users'
     and new.data->>'status' = 'active'
     and (old.data->>'status' is distinct from 'active') then
    new.data := (new.data - 'lockedAt' - 'lockUntil')
      || jsonb_build_object('failCount', 0, 'locked', false);
  end if;
  return new;
end $$;

drop trigger if exists mm_users_clear_lock_on_active on public.mm_rows;
create trigger mm_users_clear_lock_on_active
  before update on public.mm_rows
  for each row execute function public.mm_users_clear_lock_on_active();

revoke all on function public.mm_valid_bizno(text) from public, anon, authenticated;
revoke all on function public.mm_me(text), public.mm_login(text, text),
  public.mm_signup(text, text, text), public.mm_signup(text, text, text, text),
  public.mm_unlock(text, text), public.mm_reset_password(text, text),
  public.mm_users_clear_lock_on_active() from public, anon, authenticated;

grant execute on function public.mm_login(text, text),
  public.mm_signup(text, text, text), public.mm_signup(text, text, text, text),
  public.mm_unlock(text, text), public.mm_reset_password(text, text)
  to anon, authenticated;

notify pgrst, 'reload schema';
