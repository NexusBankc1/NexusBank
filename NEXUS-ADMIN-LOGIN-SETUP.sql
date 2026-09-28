-- NEXUS administrator profile setup for the current profiles table.
-- Replace only the email if your administrator email differs. Never put a password here.
UPDATE public.profiles
SET role='admin', is_active=true, updated_at=now()
WHERE id=(SELECT id FROM auth.users WHERE email='deanlewis1x@gmail.com');

SELECT id,email,full_name,phone,role,is_active,created_at,updated_at
FROM public.profiles
WHERE email='deanlewis1x@gmail.com';
