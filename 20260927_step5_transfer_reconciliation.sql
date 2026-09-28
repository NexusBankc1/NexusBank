-- NEXUS STEP 5
-- Reconcile the existing send-money flow with the transaction PIN + OTP security layer.
-- This migration does NOT expose OTP codes to the client or admin dashboard.
-- OTP delivery is handled by the Edge Function added in this package.

create table if not exists public.transfer_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete restrict,
  account_id uuid not null references public.accounts(id) on delete restrict,
  recipient_account_number text not null,
  recipient_name text not null,
  recipient_bank text not null,
  amount numeric(24,8) not null check (amount > 0),
  currency text not null,
  reference text unique not null,
  status text not null default 'awaiting_otp'
    check (status in ('awaiting_otp','pending','completed','failed','cancelled','expired')),
  pin_verified_at timestamptz not null default now(),
  completed_at timestamptz,
  transaction_id uuid references public.transactions(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.transfer_otp_challenges (
  id uuid primary key default gen_random_uuid(),
  transfer_request_id uuid not null references public.transfer_requests(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete restrict,
  code_hash text not null,
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 5 check (max_attempts > 0),
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_transfer_requests_user_created
  on public.transfer_requests(user_id, created_at desc);
create index if not exists idx_transfer_requests_status
  on public.transfer_requests(status, created_at desc);
create index if not exists idx_transfer_otp_request
  on public.transfer_otp_challenges(transfer_request_id, created_at desc);

alter table public.transfer_requests enable row level security;
alter table public.transfer_otp_challenges enable row level security;

drop policy if exists transfer_requests_self on public.transfer_requests;
create policy transfer_requests_self on public.transfer_requests
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists transfer_otp_admin_safe_view on public.transfer_otp_challenges;
create policy transfer_otp_admin_safe_view on public.transfer_otp_challenges
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- Create a transfer request after validating the user's transaction PIN.
-- No funds are moved here and no OTP code is returned.
create or replace function public.create_transfer_request(
  p_recipient_account_number text,
  p_amount numeric,
  p_reference text,
  p_pin text
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  s public.accounts;
  r public.recipient_accounts;
  p public.profiles;
  req public.transfer_requests;
  pin_ok boolean;
  ref text;
begin
  select * into p from public.profiles where id = auth.uid();
  if not found or p.status = 'deactivated' or p.deleted_at is not null then
    return jsonb_build_object('success',false,'message','This account is unavailable at this moment.');
  end if;

  select * into s
  from public.accounts
  where user_id = auth.uid() and deleted_at is null
  order by created_at desc
  limit 1 for update;
  if not found then
    return jsonb_build_object('success',false,'message','No active account was found.');
  end if;

  if s.status = 'frozen' then
    return jsonb_build_object('success',false,'message','This account is frozen. You cannot make a transfer at this moment. Kindly contact Customer Care for further information and support.');
  end if;

  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('success',false,'message','Enter a valid amount.');
  end if;

  if p_amount > s.balance then
    return jsonb_build_object('success',false,'message','Insufficient available balance.');
  end if;

  select * into r
  from public.recipient_accounts
  where account_number = trim(p_recipient_account_number) and status = 'active';
  if not found then
    return jsonb_build_object('success',false,'message','Recipient account was not found.');
  end if;

  select transaction_pin_hash is not null
         and crypt(p_pin, transaction_pin_hash) = transaction_pin_hash
    into pin_ok
  from public.profiles where id = auth.uid();

  if not coalesce(pin_ok,false) then
    return jsonb_build_object('success',false,'message','Invalid transaction PIN.');
  end if;

  ref := coalesce(nullif(trim(p_reference),''), 'NXS-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)));

  -- Avoid duplicate active requests using the same generated/reference value.
  if exists (
    select 1 from public.transfer_requests
    where user_id = auth.uid()
      and reference = ref
      and status in ('awaiting_otp','pending')
  ) then
    return jsonb_build_object('success',false,'message','A transfer request with this reference is already active.');
  end if;

  insert into public.transfer_requests(
    user_id, account_id, recipient_account_number, recipient_name,
    recipient_bank, amount, currency, reference, status, metadata
  ) values (
    auth.uid(), s.id, r.account_number, r.account_name,
    r.bank_name, p_amount, s.currency, ref, 'awaiting_otp',
    jsonb_build_object('created_from','send_money')
  ) returning * into req;

  return jsonb_build_object(
    'success',true,
    'message','Transaction PIN accepted. OTP verification is required.',
    'transfer_request_id',req.id,
    'reference',req.reference,
    'expires_at',req.expires_at
  );
end; $$;

grant execute on function public.create_transfer_request(text,numeric,text,text) to authenticated;

-- Called only after the server has received the OTP code from the user.
-- The code is compared against a bcrypt hash and is never stored in plaintext.
create or replace function public.verify_transfer_otp(
  p_transfer_request_id uuid,
  p_otp text
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  req public.transfer_requests;
  ch public.transfer_otp_challenges;
  s public.accounts;
  t public.transactions;
  pin_code_ok boolean;
  ref text;
begin
  select * into req
  from public.transfer_requests
  where id = p_transfer_request_id and user_id = auth.uid()
  for update;
  if not found then
    return jsonb_build_object('success',false,'message','Transfer request not found.');
  end if;

  if req.status <> 'awaiting_otp' then
    return jsonb_build_object('success',false,'message','This transfer request is no longer awaiting OTP verification.');
  end if;

  if now() > req.expires_at then
    update public.transfer_requests set status='expired' where id=req.id;
    return jsonb_build_object('success',false,'message','This transfer request has expired.');
  end if;

  select * into ch
  from public.transfer_otp_challenges
  where transfer_request_id=req.id and user_id=auth.uid() and consumed_at is null
  order by created_at desc
  limit 1
  for update;
  if not found then
    return jsonb_build_object('success',false,'message','No active OTP challenge was found.');
  end if;

  if now() > ch.expires_at then
    return jsonb_build_object('success',false,'message','The OTP has expired. Request a new code.');
  end if;

  if ch.attempts >= ch.max_attempts then
    return jsonb_build_object('success',false,'message','Too many incorrect OTP attempts. Request a new code.');
  end if;

  if ch.code_hash <> crypt(trim(p_otp), ch.code_hash) then
    update public.transfer_otp_challenges set attempts=attempts+1 where id=ch.id;
    return jsonb_build_object('success',false,'message','Invalid OTP code.');
  end if;

  update public.transfer_otp_challenges set consumed_at=now() where id=ch.id;

  select * into s
  from public.accounts
  where id=req.account_id and user_id=auth.uid() and deleted_at is null
  for update;
  if not found then
    update public.transfer_requests set status='failed' where id=req.id;
    return jsonb_build_object('success',false,'message','No active account was found.');
  end if;

  if s.status='frozen' then
    update public.transfer_requests set status='failed' where id=req.id;
    return jsonb_build_object('success',false,'message','This account is frozen. You cannot make a transfer at this moment. Kindly contact Customer Care for further information and support.');
  end if;

  if s.balance < req.amount then
    update public.transfer_requests set status='failed' where id=req.id;
    return jsonb_build_object('success',false,'message','Insufficient available balance.');
  end if;

  ref := req.reference;

  if s.status='pending' then
    insert into public.transactions(
      account_id,user_id,type,category,amount,currency,status,description,reference,metadata
    ) values (
      s.id,s.user_id,'transfer','customer',req.amount,s.currency,'pending',
      'Transfer to '||req.recipient_name,ref,
      jsonb_build_object(
        'recipient_account_number',req.recipient_account_number,
        'recipient_name',req.recipient_name,
        'bank_name',req.recipient_bank,
        'transfer_request_id',req.id
      )
    ) returning * into t;

    update public.transfer_requests
      set status='pending', transaction_id=t.id
      where id=req.id;

    insert into public.notifications(user_id,type,title,message,transaction_id)
      values(req.user_id,'transaction','Transfer pending',
             'Your transfer is pending because your account is currently pending.',t.id);

    return jsonb_build_object('success',true,'message','Transaction is pending.', 'transaction',to_jsonb(t));
  end if;

  -- Active accounts are debited only after successful OTP verification.
  update public.accounts set balance=balance-req.amount where id=s.id;

  insert into public.transactions(
    account_id,user_id,type,category,amount,currency,status,description,reference,metadata
  ) values (
    s.id,s.user_id,'transfer','customer',req.amount,s.currency,'completed',
    'Transfer to '||req.recipient_name,ref,
    jsonb_build_object(
      'recipient_account_number',req.recipient_account_number,
      'recipient_name',req.recipient_name,
      'bank_name',req.recipient_bank,
      'transfer_request_id',req.id
    )
  ) returning * into t;

  update public.transfer_requests
    set status='completed', completed_at=now(), transaction_id=t.id
    where id=req.id;

  insert into public.notifications(user_id,type,title,message,transaction_id)
    values(req.user_id,'transaction','Transfer completed',
           'Your transfer to '||req.recipient_name||' was completed.',t.id);

  return jsonb_build_object('success',true,'message','Transfer completed.','transaction',to_jsonb(t));
end; $$;

grant execute on function public.verify_transfer_otp(uuid,text) to authenticated;

create or replace function public.cancel_transfer_request(p_transfer_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  update public.transfer_requests
    set status='cancelled'
  where id=p_transfer_request_id
    and user_id=auth.uid()
    and status='awaiting_otp';
  if not found then
    return jsonb_build_object('success',false,'message','Transfer request could not be cancelled.');
  end if;
  return jsonb_build_object('success',true,'message','Transfer request cancelled.');
end; $$;

grant execute on function public.cancel_transfer_request(uuid) to authenticated;

-- Utility used by the Edge Function to create a challenge after it has generated
-- the one-time code. The plaintext code is supplied only to this function call,
-- then immediately converted to a bcrypt hash.
create or replace function public.create_transfer_otp_challenge(
  p_transfer_request_id uuid,
  p_code text
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare req public.transfer_requests; ch public.transfer_otp_challenges;
begin
  select * into req from public.transfer_requests
  where id=p_transfer_request_id and user_id=auth.uid() and status='awaiting_otp'
  for update;
  if not found then
    return jsonb_build_object('success',false,'message','Transfer request is not available.');
  end if;
  if now() > req.expires_at then
    update public.transfer_requests set status='expired' where id=req.id;
    return jsonb_build_object('success',false,'message','Transfer request has expired.');
  end if;
  if p_code !~ '^[0-9]{6}$' then
    return jsonb_build_object('success',false,'message','Invalid OTP format.');
  end if;

  update public.transfer_otp_challenges
    set consumed_at=now()
  where transfer_request_id=req.id and user_id=auth.uid() and consumed_at is null;

  insert into public.transfer_otp_challenges(transfer_request_id,user_id,code_hash)
    values(req.id,auth.uid(),crypt(p_code,gen_salt('bf')))
    returning * into ch;

  return jsonb_build_object('success',true,'challenge_id',ch.id,'expires_at',ch.expires_at);
end; $$;

grant execute on function public.create_transfer_otp_challenge(uuid,text) to authenticated;

-- Never expose plaintext OTPs through views or admin queries.
create or replace view public.admin_transfer_security_events as
select
  tr.id as transfer_request_id,
  tr.user_id,
  tr.reference,
  tr.amount,
  tr.currency,
  tr.status as transfer_status,
  tr.created_at,
  tr.expires_at,
  c.created_at as otp_created_at,
  c.expires_at as otp_expires_at,
  c.attempts,
  c.max_attempts,
  (c.consumed_at is not null) as otp_consumed
from public.transfer_requests tr
left join lateral (
  select * from public.transfer_otp_challenges x
  where x.transfer_request_id=tr.id
  order by x.created_at desc
  limit 1
) c on true;

-- Admins can audit OTP challenge state, but the OTP code itself is never exposed.
grant select on public.admin_transfer_security_events to authenticated;
