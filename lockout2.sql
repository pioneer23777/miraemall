-- 미래몰: 사업자번호 없는 3인자 가입 함수 제거
-- Supabase SQL Editor에서 실행. 여러 번 실행해도 안전.
-- 4인자 mm_signup(p_name, p_phone, p_pw, p_bizno) 과 권한은 그대로 둡니다.

drop function if exists public.mm_signup(text, text, text);

revoke all on function public.mm_signup(text, text, text, text) from public;
grant execute on function public.mm_signup(text, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';
