-- NEXUS Supabase backend
-- Apply this file in the Supabase SQL Editor.
-- This is an application/test banking UI foundation. It is not a regulated bank ledger.
-- Original transaction creation timestamps are immutable. Admin-edited dates are stored separately.

create extension if not exists pgcrypto;

do $$ begin
  create type public.user_role as enum ('customer','admin');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.account_status as enum ('active','pending','frozen');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.profile_status as enum ('active','deactivated');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.tx_status as enum ('pending','processing','completed','failed','cancelled');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null default '', full_name text not null default '', phone text,
  role public.user_role not null default 'customer', status public.profile_status not null default 'active',
  transaction_pin_hash text, deleted_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.accounts (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete restrict,
  account_number text not null unique, email text, full_name text not null default '', bank_name text not null default 'NEXUS',
  routing_identifier text not null default '', currency text not null default 'USD',
  balance numeric(24,8) not null default 0 check(balance>=0), status public.account_status not null default 'active',
  crypto_balances jsonb not null default '{"BTC":{"balance":0},"USDT":{"balance":0}}'::jsonb,
  crypto_wallets jsonb not null default '{}'::jsonb, deleted_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.recipient_accounts (
  id uuid primary key default gen_random_uuid(), account_number text not null unique,
  account_name text not null, bank_name text not null, status text not null default 'active' check(status in ('active','inactive')),
  created_by uuid references public.profiles(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(), account_id uuid not null references public.accounts(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict, type text not null, category text,
  amount numeric(24,8) not null, currency text not null, status public.tx_status not null default 'completed',
  description text, reference text unique, created_at timestamptz not null default now(),
  display_transaction_at timestamptz, date_corrected_by uuid references public.profiles(id), date_corrected_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null default 'system', title text not null, message text not null,
  transaction_id uuid references public.transactions(id) on delete set null,
  is_read boolean not null default false, is_deleted boolean not null default false, created_at timestamptz not null default now()
);

create table if not exists public.crypto_transactions (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete restrict,
  account_id uuid not null references public.accounts(id) on delete restrict, asset text not null check(asset in ('BTC','USDT')),
  type text not null, amount numeric(30,12) not null, network text, status text not null default 'pending',
  reference text unique, destination text, created_at timestamptz not null default now(), metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.deposits (
  id uuid primary key default gen_random_uuid(), account_id uuid not null references public.accounts(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict, amount numeric(24,8) not null,
  currency text not null, method text not null default 'manual', status text not null default 'pending' check(status in ('pending','completed','failed','cancelled')),
  note text, reviewed_by uuid references public.profiles(id), created_at timestamptz not null default now(), reviewed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.withdrawals (
  id uuid primary key default gen_random_uuid(), account_id uuid not null references public.accounts(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict, amount numeric(24,8) not null,
  currency text not null, destination text not null default '', status text not null default 'pending' check(status in ('pending','processing','completed','failed','cancelled')),
  note text, reviewed_by uuid references public.profiles(id), created_at timestamptz not null default now(), reviewed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.audit_logs (
  id bigint generated always as identity primary key, admin_user_id uuid references public.profiles(id), action text not null,
  target_user_id uuid references public.profiles(id), account_id uuid references public.accounts(id), metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.platform_settings (
  id integer primary key default 1 check(id=1), customer_care_email text not null default 'support@example.com',
  customer_care_whatsapp text not null default '', updated_by uuid references public.profiles(id), updated_at timestamptz not null default now()
);
insert into public.platform_settings(id) values(1) on conflict(id) do nothing;

create index if not exists idx_accounts_user on public.accounts(user_id) where deleted_at is null;
create index if not exists idx_accounts_status on public.accounts(status) where deleted_at is null;
create index if not exists idx_transactions_account_date on public.transactions(account_id, display_transaction_at desc, created_at desc);
create index if not exists idx_notifications_user_date on public.notifications(user_id, created_at desc);
create index if not exists idx_profiles_deleted on public.profiles(deleted_at);
create index if not exists idx_deposits_status on public.deposits(status, created_at desc);
create index if not exists idx_withdrawals_status on public.withdrawals(status, created_at desc);

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles where id=auth.uid() and role='admin' and status='active' and deleted_at is null);
$$;

grant execute on function public.is_admin() to authenticated;

create or replace function public.set_updated_at() returns trigger language plpgsql as $$ begin new.updated_at=now(); return new; end; $$;
drop trigger if exists profiles_updated_at on public.profiles; create trigger profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
drop trigger if exists accounts_updated_at on public.accounts; create trigger accounts_updated_at before update on public.accounts for each row execute function public.set_updated_at();
drop trigger if exists recipients_updated_at on public.recipient_accounts; create trigger recipients_updated_at before update on public.recipient_accounts for each row execute function public.set_updated_at();


create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id,email,full_name,role) values(new.id,coalesce(new.email,''),coalesce(new.raw_user_meta_data->>'full_name',''),'customer')
  on conflict(id) do update set email=excluded.email;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.admin_set_transaction_pin(p_user_id uuid,p_pin text) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if p_pin !~ '^[0-9]{4,6}$' then raise exception 'Invalid transaction PIN'; end if;
 update public.profiles set transaction_pin_hash=crypt(p_pin,gen_salt('bf')),updated_at=now() where id=p_user_id;
end; $$;

create or replace function public.submit_transfer(p_recipient_account_number text,p_amount numeric,p_reference text,p_pin text) returns jsonb language plpgsql security definer set search_path=public as $$
declare s public.accounts; r public.recipient_accounts; t public.transactions; pin_ok boolean; ref text; p public.profiles;
begin
 select * into p from public.profiles where id=auth.uid();
 if not found or p.status='deactivated' or p.deleted_at is not null then return jsonb_build_object('success',false,'message','This account is unavailable at this moment.'); end if;
 select * into s from public.accounts where user_id=auth.uid() and deleted_at is null limit 1 for update;
 if not found then return jsonb_build_object('success',false,'message','No active account was found.'); end if;
 if s.status='frozen' then return jsonb_build_object('success',false,'message','This account is frozen. You cannot make a transfer at this moment. Kindly contact Customer Care for further information and support.'); end if;
 if p_amount is null or p_amount<=0 then return jsonb_build_object('success',false,'message','Enter a valid amount.'); end if;
 if p_amount>s.balance then return jsonb_build_object('success',false,'message','Insufficient available balance.'); end if;
 select * into r from public.recipient_accounts where account_number=trim(p_recipient_account_number) and status='active';
 if not found then return jsonb_build_object('success',false,'message','Recipient account was not found.'); end if;
 select transaction_pin_hash is not null and crypt(p_pin,transaction_pin_hash)=transaction_pin_hash into pin_ok from public.profiles where id=auth.uid();
 if not coalesce(pin_ok,false) then return jsonb_build_object('success',false,'message','Invalid transaction PIN.'); end if;
 ref:=coalesce(nullif(p_reference,''),'NXS-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)));
 if s.status='pending' then
   insert into public.transactions(account_id,user_id,type,amount,currency,status,description,reference,metadata) values(s.id,s.user_id,'transfer',p_amount,s.currency,'pending','Transfer to '||r.account_name,ref,jsonb_build_object('recipient_account_number',r.account_number,'recipient_name',r.account_name,'bank_name',r.bank_name)) returning * into t;
   insert into public.notifications(user_id,type,title,message,transaction_id) values(s.user_id,'transaction','Transfer pending','Your transfer is pending because your account is currently pending.',t.id);
   return jsonb_build_object('success',true,'message','Transaction is pending.','transaction',to_jsonb(t));
 end if;
 s.balance:=s.balance-p_amount; update public.accounts set balance=s.balance where id=s.id;
 insert into public.transactions(account_id,user_id,type,amount,currency,status,description,reference,metadata) values(s.id,s.user_id,'transfer',p_amount,s.currency,'completed','Transfer to '||r.account_name,ref,jsonb_build_object('recipient_account_number',r.account_number,'recipient_name',r.account_name,'bank_name',r.bank_name)) returning * into t;
 insert into public.notifications(user_id,type,title,message,transaction_id) values(s.user_id,'transaction','Transfer completed','Your transfer to '||r.account_name||' was completed.',t.id);
 return jsonb_build_object('success',true,'message','Transfer completed.','transaction',to_jsonb(t));
end; $$;
grant execute on function public.submit_transfer(text,numeric,text,text) to authenticated;

create or replace function public.process_pending_transfers(p_user_id uuid) returns integer language plpgsql security definer set search_path=public as $$
declare t public.transactions; a public.accounts; processed integer:=0;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 select * into a from public.accounts where user_id=p_user_id and deleted_at is null limit 1 for update;
 if not found or a.status<>'active' then return 0; end if;
 for t in select * from public.transactions where user_id=p_user_id and account_id=a.id and status='pending' order by created_at for update loop
   if a.balance < t.amount then update public.transactions set status='failed' where id=t.id; insert into public.notifications(user_id,type,title,message,transaction_id) values(p_user_id,'transaction','Pending transfer failed','A pending transfer could not be completed because the available balance is insufficient.',t.id);
   else a.balance:=a.balance-t.amount; update public.accounts set balance=a.balance where id=a.id; update public.transactions set status='completed' where id=t.id; insert into public.notifications(user_id,type,title,message,transaction_id) values(p_user_id,'transaction','Pending transfer completed','A previously pending transfer has now been completed.',t.id); processed:=processed+1; end if;
 end loop;
 update public.accounts set balance=a.balance where id=a.id; return processed;
end; $$;
grant execute on function public.process_pending_transfers(uuid) to authenticated;



create or replace function public.process_pending_crypto_conversions(p_user_id uuid) returns integer language plpgsql security definer set search_path=public as $$
declare t public.crypto_transactions; a public.accounts; old numeric; newv numeric; processed integer:=0; cb jsonb; ref text;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 select * into a from public.accounts where user_id=p_user_id and deleted_at is null limit 1 for update;
 if not found or a.status<>'active' then return 0; end if;
 for t in select * from public.crypto_transactions where user_id=p_user_id and account_id=a.id and type in ('to_crypto','to_account') and status='pending' order by created_at for update loop
   old:=coalesce((a.crypto_balances->t.asset->>'balance')::numeric,0);
   if t.type='to_crypto' then
     if a.balance<t.amount then update public.crypto_transactions set status='failed' where id=t.id; insert into public.notifications(user_id,type,title,message) values(p_user_id,'crypto','Pending crypto conversion failed','The conversion could not be completed because the account balance is insufficient.');
     else a.balance:=a.balance-t.amount; newv:=old+t.amount; cb:=jsonb_set(coalesce(a.crypto_balances,'{}'::jsonb),array[t.asset],jsonb_build_object('asset',t.asset,'balance',newv),true); update public.accounts set balance=a.balance,crypto_balances=cb where id=a.id; a.crypto_balances=cb; update public.crypto_transactions set status='completed' where id=t.id; ref:='NXS-CR-CONV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)); insert into public.transactions(account_id,user_id,type,category,amount,currency,status,description,reference) values(a.id,a.user_id,'crypto_conversion','crypto',t.amount,a.currency,'completed','Pending conversion to '||t.asset,ref); insert into public.notifications(user_id,type,title,message) values(p_user_id,'crypto','Pending crypto conversion completed','A previously pending crypto conversion has now been completed.'); processed:=processed+1; end if;
   else
     if old<t.amount then update public.crypto_transactions set status='failed' where id=t.id; insert into public.notifications(user_id,type,title,message) values(p_user_id,'crypto','Pending crypto conversion failed','The conversion could not be completed because the crypto balance is insufficient.');
     else newv:=old-t.amount; a.balance:=a.balance+t.amount; cb:=jsonb_set(coalesce(a.crypto_balances,'{}'::jsonb),array[t.asset],jsonb_build_object('asset',t.asset,'balance',newv),true); update public.accounts set balance=a.balance,crypto_balances=cb where id=a.id; a.crypto_balances=cb; update public.crypto_transactions set status='completed' where id=t.id; ref:='NXS-CR-CONV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)); insert into public.transactions(account_id,user_id,type,category,amount,currency,status,description,reference) values(a.id,a.user_id,'crypto_conversion','crypto',t.amount,a.currency,'completed','Pending conversion from '||t.asset,ref); insert into public.notifications(user_id,type,title,message) values(p_user_id,'crypto','Pending crypto conversion completed','A previously pending crypto conversion has now been completed.'); processed:=processed+1; end if;
   end if;
 end loop;
 return processed;
end; $$;
grant execute on function public.process_pending_crypto_conversions(uuid) to authenticated;

create or replace function public.process_pending_crypto_sends(p_user_id uuid) returns integer language plpgsql security definer set search_path=public as $$
declare t public.crypto_transactions; a public.accounts; old numeric; cb jsonb; processed integer:=0;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 select * into a from public.accounts where user_id=p_user_id and deleted_at is null limit 1 for update;
 if not found or a.status<>'active' then return 0; end if;
 for t in select * from public.crypto_transactions where user_id=p_user_id and account_id=a.id and type='send' and status='pending' order by created_at for update loop
   old:=coalesce((a.crypto_balances->t.asset->>'balance')::numeric,0);
   if old<t.amount then
     update public.crypto_transactions set status='failed' where id=t.id;
     insert into public.notifications(user_id,type,title,message) values(p_user_id,'crypto','Pending crypto transaction failed','A pending crypto transaction could not be completed because the available crypto balance is insufficient.');
   else
     cb:=jsonb_set(coalesce(a.crypto_balances,'{}'::jsonb),array[t.asset],jsonb_build_object('asset',t.asset,'balance',old-t.amount),true);
     update public.accounts set crypto_balances=cb where id=a.id; a.crypto_balances=cb;
     update public.crypto_transactions set status='completed' where id=t.id;
     insert into public.notifications(user_id,type,title,message) values(p_user_id,'crypto','Pending crypto transaction completed','A previously pending crypto transaction has now been completed.');
     processed:=processed+1;
   end if;
 end loop;
 return processed;
end; $$;
grant execute on function public.process_pending_crypto_sends(uuid) to authenticated;

create or replace function public.process_pending_withdrawals(p_user_id uuid) returns integer language plpgsql security definer set search_path=public as $$
declare w public.withdrawals; a public.accounts; processed integer:=0; ref text;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 select * into a from public.accounts where user_id=p_user_id and deleted_at is null limit 1 for update;
 if not found or a.status<>'active' then return 0; end if;
 for w in select * from public.withdrawals where user_id=p_user_id and account_id=a.id and status='pending' order by created_at for update loop
   if a.balance<w.amount then
     update public.withdrawals set status='failed',reviewed_by=auth.uid(),reviewed_at=now() where id=w.id;
     insert into public.notifications(user_id,type,title,message) values(p_user_id,'transaction','Pending withdrawal failed','A pending withdrawal could not be completed because the available balance is insufficient.');
   else
     a.balance:=a.balance-w.amount; update public.accounts set balance=a.balance where id=a.id;
     ref:='NXS-WD-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
     update public.withdrawals set status='completed',reviewed_by=auth.uid(),reviewed_at=now() where id=w.id;
     insert into public.transactions(account_id,user_id,type,category,amount,currency,status,description,reference) values(a.id,a.user_id,'withdrawal','customer',w.amount,a.currency,'completed','Withdrawal to '||w.destination,ref);
     insert into public.notifications(user_id,type,title,message) values(p_user_id,'transaction','Pending withdrawal completed','A previously pending withdrawal has now been completed.');
     processed:=processed+1;
   end if;
 end loop;
 return processed;
end; $$;
grant execute on function public.process_pending_withdrawals(uuid) to authenticated;

create or replace function public.admin_set_account_status(p_account_id uuid,p_status public.account_status) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.accounts;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 update public.accounts set status=p_status where id=p_account_id and deleted_at is null returning * into a;
 if not found then raise exception 'Account not found'; end if;
 insert into public.audit_logs(admin_user_id,action,target_user_id,account_id,metadata) values(auth.uid(),'account_status_changed',a.user_id,a.id,jsonb_build_object('status',p_status));
 if p_status='frozen' then insert into public.notifications(user_id,type,title,message) values(a.user_id,'account','Account frozen','This account is currently frozen. You cannot make transfers or restricted transactions at this time. Kindly contact Customer Care for further information and support.'); end if;
 if p_status='pending' then insert into public.notifications(user_id,type,title,message) values(a.user_id,'account','Account pending','Your account is currently pending. New money and cryptocurrency transactions will remain pending until the account returns to active status.'); end if;
 if p_status='active' then insert into public.notifications(user_id,type,title,message) values(a.user_id,'account','Account active','Your account has been returned to active status. Normal account operations are available.'); perform public.process_pending_transfers(a.user_id); perform public.process_pending_crypto_conversions(a.user_id); perform public.process_pending_crypto_sends(a.user_id); perform public.process_pending_withdrawals(a.user_id); end if;
 return jsonb_build_object('success',true,'status',p_status);
end; $$;
grant execute on function public.admin_set_account_status(uuid,public.account_status) to authenticated;

create or replace function public.admin_soft_delete_account(p_account_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.accounts;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 update public.accounts set deleted_at=now() where id=p_account_id and deleted_at is null returning * into a;
 if not found then raise exception 'Account not found'; end if;
 update public.profiles set deleted_at=now() where id=a.user_id;
 insert into public.audit_logs(admin_user_id,action,target_user_id,account_id,metadata) values(auth.uid(),'account_soft_deleted',a.user_id,a.id,'{}');
 return jsonb_build_object('success',true);
end; $$;
grant execute on function public.admin_soft_delete_account(uuid) to authenticated;

create or replace function public.admin_restore_account(p_user_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.accounts;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 update public.profiles set deleted_at=null,status='active' where id=p_user_id;
 update public.accounts set deleted_at=null,status='active' where user_id=p_user_id returning * into a;
 if not found then raise exception 'Account not found'; end if;
 insert into public.notifications(user_id,type,title,message) values(p_user_id,'account','Account restored','Your NEXUS account has been restored and is active again.');
 insert into public.audit_logs(admin_user_id,action,target_user_id,account_id,metadata) values(auth.uid(),'account_restored',p_user_id,a.id,'{}');
 return jsonb_build_object('success',true);
end; $$;
grant execute on function public.admin_restore_account(uuid) to authenticated;

create or replace function public.admin_deactivate_account(p_account_id uuid,p_deactivated boolean) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.accounts;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 select * into a from public.accounts where id=p_account_id;
 if not found then raise exception 'Account not found'; end if;
 update public.profiles set status=case when p_deactivated then 'deactivated' else 'active' end where id=a.user_id;
 if not p_deactivated then update public.accounts set status='active' where id=a.id and deleted_at is null; perform public.process_pending_transfers(a.user_id); perform public.process_pending_crypto_conversions(a.user_id); perform public.process_pending_crypto_sends(a.user_id); perform public.process_pending_withdrawals(a.user_id); end if;
 insert into public.audit_logs(admin_user_id,action,target_user_id,account_id,metadata) values(auth.uid(),case when p_deactivated then 'account_deactivated' else 'account_reactivated' end,a.user_id,a.id,'{}');
 insert into public.notifications(user_id,type,title,message) values(a.user_id,'account',case when p_deactivated then 'Account unavailable' else 'Account reactivated' end,case when p_deactivated then 'Your account is currently unavailable. Please contact Customer Care for support.' else 'Your account has been reactivated. Normal account operations are available.' end);
 return jsonb_build_object('success',true);
end; $$;
grant execute on function public.admin_deactivate_account(uuid,boolean) to authenticated;

create or replace function public.admin_update_transaction_date(p_transaction_id uuid,p_display_transaction_at timestamptz) returns jsonb language plpgsql security definer set search_path=public as $$
declare t public.transactions;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 update public.transactions set display_transaction_at=p_display_transaction_at,date_corrected_by=auth.uid(),date_corrected_at=now() where id=p_transaction_id returning * into t;
 if not found then raise exception 'Transaction not found'; end if;
 insert into public.audit_logs(admin_user_id,action,target_user_id,account_id,metadata) values(auth.uid(),'transaction_display_date_changed',t.user_id,t.account_id,jsonb_build_object('transaction_id',t.id,'original_created_at',t.created_at,'display_transaction_at',p_display_transaction_at));
 return jsonb_build_object('success',true,'transaction',to_jsonb(t));
end; $$;
grant execute on function public.admin_update_transaction_date(uuid,timestamptz) to authenticated;

create or replace function public.admin_fund_account(p_account_id uuid,p_amount numeric,p_note text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.accounts; t public.transactions; ref text;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'Enter a valid amount'; end if;
 select * into a from public.accounts where id=p_account_id and deleted_at is null for update;
 if not found then raise exception 'Account not found'; end if;
 if a.status='frozen' then raise exception 'Account is frozen'; end if;
 a.balance:=a.balance+p_amount; update public.accounts set balance=a.balance where id=a.id;
 ref:='NXS-DEP-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
 insert into public.deposits(account_id,user_id,amount,currency,method,status,note,reviewed_by,reviewed_at) values(a.id,a.user_id,p_amount,a.currency,'admin','completed',p_note,auth.uid(),now());
 insert into public.transactions(account_id,user_id,type,category,amount,currency,status,description,reference) values(a.id,a.user_id,'deposit','admin',p_amount,a.currency,'completed',coalesce(p_note,'Funds added by NEXUS administrator'),ref) returning * into t;
 insert into public.notifications(user_id,type,title,message,transaction_id) values(a.user_id,'transaction','Funds added','Funds were added to your NEXUS account.',t.id);
 insert into public.audit_logs(admin_user_id,action,target_user_id,account_id,metadata) values(auth.uid(),'admin_funded_account',a.user_id,a.id,jsonb_build_object('amount',p_amount,'currency',a.currency,'transaction_id',t.id));
 return jsonb_build_object('success',true,'transaction',to_jsonb(t),'new_balance',a.balance);
end; $$;
grant execute on function public.admin_fund_account(uuid,numeric,text) to authenticated;

create or replace function public.admin_update_customer_care(p_email text,p_whatsapp text) returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 update public.platform_settings set customer_care_email=coalesce(nullif(trim(p_email),''),'support@example.com'),customer_care_whatsapp=coalesce(trim(p_whatsapp),''),updated_by=auth.uid(),updated_at=now() where id=1;
 insert into public.audit_logs(admin_user_id,action,metadata) values(auth.uid(),'customer_care_settings_updated',jsonb_build_object('email',p_email,'whatsapp',p_whatsapp));
 return jsonb_build_object('success',true);
end; $$;
grant execute on function public.admin_update_customer_care(text,text) to authenticated;

create or replace function public.admin_create_recipient(p_number text,p_name text,p_bank text) returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.recipient_accounts;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if trim(p_number)='' or trim(p_name)='' or trim(p_bank)='' then raise exception 'Account number, account name and bank name are required'; end if;
 insert into public.recipient_accounts(account_number,account_name,bank_name,created_by) values(trim(p_number),trim(p_name),trim(p_bank),auth.uid()) returning * into r;
 insert into public.audit_logs(admin_user_id,action,metadata) values(auth.uid(),'recipient_account_created',jsonb_build_object('recipient_id',r.id,'account_number',r.account_number,'bank_name',r.bank_name));
 return jsonb_build_object('success',true,'recipient',to_jsonb(r));
end; $$;
grant execute on function public.admin_create_recipient(text,text,text) to authenticated;

create or replace function public.admin_save_crypto_wallet(p_account_id uuid,p_asset text,p_network text,p_address text,p_label text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.accounts; w jsonb;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if p_asset not in ('BTC','USDT') then raise exception 'Unsupported crypto asset'; end if;
 if p_asset='BTC' and p_network<>'BTC' then raise exception 'Bitcoin must use BTC network'; end if;
 if p_asset='USDT' and p_network not in ('TRC20','ERC20') then raise exception 'USDT must use TRC20 or ERC20'; end if;
 select * into a from public.accounts where id=p_account_id and deleted_at is null;
 if not found then raise exception 'Account not found'; end if;
 w:=jsonb_build_object('asset',p_asset,'network',p_network,'address',trim(p_address),'label',coalesce(nullif(trim(p_label),''),'NEXUS '||p_asset||' wallet'),'status','active','updated_at',now(),'updated_by',auth.uid());
 update public.accounts set crypto_wallets=jsonb_set(coalesce(crypto_wallets,'{}'::jsonb),array[p_asset],w,true) where id=a.id;
 insert into public.audit_logs(admin_user_id,action,target_user_id,account_id,metadata) values(auth.uid(),'crypto_wallet_updated',a.user_id,a.id,w);
 return jsonb_build_object('success',true);
end; $$;
grant execute on function public.admin_save_crypto_wallet(uuid,text,text,text,text) to authenticated;

create or replace function public.admin_credit_crypto(p_account_id uuid,p_asset text,p_amount numeric,p_network text,p_note text,p_reference text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.accounts; old numeric; newv numeric; t public.crypto_transactions; ref text; cb jsonb;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if p_asset not in ('BTC','USDT') or p_amount is null or p_amount<=0 then raise exception 'Invalid crypto credit'; end if;
 if p_asset='BTC' and p_network<>'BTC' then raise exception 'Bitcoin must use BTC network'; end if;
 if p_asset='USDT' and p_network not in ('TRC20','ERC20') then raise exception 'USDT must use TRC20 or ERC20'; end if;
 select * into a from public.accounts where id=p_account_id and deleted_at is null for update;
 if not found then raise exception 'Account not found'; end if;
 if a.status='frozen' then raise exception 'Account is frozen'; end if;
 if p_reference is not null and exists(select 1 from public.crypto_transactions where reference=p_reference) then raise exception 'Crypto reference already exists'; end if;
 old:=coalesce((a.crypto_balances->p_asset->>'balance')::numeric,0); newv:=old+p_amount;
 cb:=jsonb_set(coalesce(a.crypto_balances,'{}'::jsonb),array[p_asset],jsonb_build_object('asset',p_asset,'balance',newv),true);
 update public.accounts set crypto_balances=cb where id=a.id;
 ref:=coalesce(nullif(p_reference,''),'NXS-CRYPTO-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)));
 insert into public.crypto_transactions(user_id,account_id,asset,type,amount,network,status,reference,metadata) values(a.user_id,a.id,p_asset,'admin_credit',p_amount,p_network,'completed',ref,jsonb_build_object('note',p_note)) returning * into t;
 insert into public.notifications(user_id,type,title,message) values(a.user_id,'crypto','Crypto balance credited',p_amount||' '||p_asset||' was credited to your crypto balance.');
 insert into public.audit_logs(admin_user_id,action,target_user_id,account_id,metadata) values(auth.uid(),'admin_crypto_credit',a.user_id,a.id,jsonb_build_object('asset',p_asset,'amount',p_amount,'network',p_network,'reference',ref));
 return jsonb_build_object('success',true,'new_balance',newv,'reference',ref,'transaction',to_jsonb(t));
end; $$;
grant execute on function public.admin_credit_crypto(uuid,text,numeric,text,text,text) to authenticated;

create or replace function public.submit_crypto_conversion(p_direction text,p_asset text,p_amount numeric,p_pin text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.accounts; p public.profiles; pin_ok boolean; tx public.crypto_transactions; old numeric; newv numeric; rate numeric:=1; ref text;
begin
 select * into p from public.profiles where id=auth.uid();
 select * into a from public.accounts where user_id=auth.uid() and deleted_at is null limit 1 for update;
 if not found or p.status='deactivated' or p.deleted_at is not null then return jsonb_build_object('success',false,'message','Account unavailable'); end if;
 if a.status='frozen' then return jsonb_build_object('success',false,'message','This account is frozen. Crypto transactions are unavailable.'); end if;
 if p_amount is null or p_amount<=0 then return jsonb_build_object('success',false,'message','Enter a valid amount'); end if;
 if p_asset not in ('BTC','USDT') then return jsonb_build_object('success',false,'message','Unsupported asset'); end if;
 select transaction_pin_hash is not null and crypt(p_pin,transaction_pin_hash)=transaction_pin_hash into pin_ok from public.profiles where id=auth.uid();
 if not coalesce(pin_ok,false) then return jsonb_build_object('success',false,'message','Invalid transaction PIN'); end if;
 old:=coalesce((a.crypto_balances->p_asset->>'balance')::numeric,0);
 if p_direction='to_crypto' then
   if a.status='pending' then insert into public.crypto_transactions(user_id,account_id,asset,type,amount,status,reference,metadata) values(a.user_id,a.id,p_asset,p_direction,p_amount,'pending','NXS-CR-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)),jsonb_build_object('direction',p_direction)); insert into public.notifications(user_id,type,title,message) values(a.user_id,'crypto','Crypto conversion pending','Your crypto conversion is pending because your account is currently pending.'); return jsonb_build_object('success',true,'message','Crypto conversion is pending.'); end if;
   if p_asset='USDT' and p_amount>a.balance then return jsonb_build_object('success',false,'message','Insufficient account balance'); end if;
   if p_asset='BTC' and p_amount>a.balance then return jsonb_build_object('success',false,'message','Insufficient account balance'); end if;
   a.balance:=a.balance-p_amount; newv:=old+p_amount; update public.accounts set balance=a.balance,crypto_balances=jsonb_set(coalesce(crypto_balances,'{}'::jsonb),array[p_asset],jsonb_build_object('asset',p_asset,'balance',newv),true) where id=a.id;
 elsif p_direction='to_account' then
   if a.status='pending' then return jsonb_build_object('success',false,'message','Transaction pending because the account is pending.'); end if;
   if old<p_amount then return jsonb_build_object('success',false,'message','Insufficient crypto balance'); end if;
   newv:=old-p_amount; a.balance:=a.balance+p_amount; update public.accounts set balance=a.balance,crypto_balances=jsonb_set(coalesce(crypto_balances,'{}'::jsonb),array[p_asset],jsonb_build_object('asset',p_asset,'balance',newv),true) where id=a.id;
 else return jsonb_build_object('success',false,'message','Invalid conversion direction'); end if;
 ref:='NXS-CR-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
 insert into public.crypto_transactions(user_id,account_id,asset,type,amount,status,reference) values(a.user_id,a.id,p_asset,p_direction,p_amount,'completed',ref) returning * into tx;
 insert into public.transactions(account_id,user_id,type,category,amount,currency,status,description,reference,metadata) values(a.id,a.user_id,'crypto_conversion','crypto',p_amount,a.currency,'completed',case when p_direction='to_crypto' then 'Converted account funds to '||p_asset else 'Converted '||p_asset||' to account funds' end,ref,jsonb_build_object('asset',p_asset,'direction',p_direction));
 insert into public.notifications(user_id,type,title,message) values(a.user_id,'crypto','Crypto conversion completed','Your '||p_asset||' conversion was completed.');
 return jsonb_build_object('success',true,'transaction',to_jsonb(tx),'new_crypto_balance',newv,'new_account_balance',a.balance);
end; $$;
grant execute on function public.submit_crypto_conversion(text,text,numeric,text) to authenticated;

create or replace function public.submit_crypto_send(p_asset text,p_amount numeric,p_destination text,p_network text,p_pin text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.accounts; p public.profiles; pin_ok boolean; old numeric; tx public.crypto_transactions; ref text; cb jsonb;
begin
 select * into p from public.profiles where id=auth.uid(); select * into a from public.accounts where user_id=auth.uid() and deleted_at is null limit 1 for update;
 if not found or p.status='deactivated' or p.deleted_at is not null then return jsonb_build_object('success',false,'message','Account unavailable'); end if;
 if a.status='frozen' then return jsonb_build_object('success',false,'message','This account is frozen. Crypto transactions are unavailable.'); end if;
 if p_amount is null or p_amount<=0 or trim(p_destination)='' then return jsonb_build_object('success',false,'message','Enter a valid amount and destination wallet.'); end if;
 select transaction_pin_hash is not null and crypt(p_pin,transaction_pin_hash)=transaction_pin_hash into pin_ok from public.profiles where id=auth.uid(); if not coalesce(pin_ok,false) then return jsonb_build_object('success',false,'message','Invalid transaction PIN'); end if;
 if a.status='pending' then insert into public.crypto_transactions(user_id,account_id,asset,type,amount,network,status,destination,reference) values(a.user_id,a.id,p_asset,'send',p_amount,p_network,'pending',trim(p_destination),'NXS-CR-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))) returning * into tx; insert into public.notifications(user_id,type,title,message) values(a.user_id,'crypto','Crypto transaction pending','Your crypto transaction is pending because your account is currently pending.'); return jsonb_build_object('success',true,'message','Crypto transaction is pending.','transaction',to_jsonb(tx)); end if;
 old:=coalesce((a.crypto_balances->p_asset->>'balance')::numeric,0); if old<p_amount then return jsonb_build_object('success',false,'message','Insufficient crypto balance'); end if;
 cb:=jsonb_set(coalesce(a.crypto_balances,'{}'::jsonb),array[p_asset],jsonb_build_object('asset',p_asset,'balance',old-p_amount),true); update public.accounts set crypto_balances=cb where id=a.id;
 ref:='NXS-CR-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)); insert into public.crypto_transactions(user_id,account_id,asset,type,amount,network,status,destination,reference) values(a.user_id,a.id,p_asset,'send',p_amount,p_network,'completed',trim(p_destination),ref) returning * into tx;
 insert into public.notifications(user_id,type,title,message) values(a.user_id,'crypto','Crypto transaction completed','Your crypto transaction was recorded as completed.');
 return jsonb_build_object('success',true,'transaction',to_jsonb(tx),'reference',ref);
end; $$;
grant execute on function public.submit_crypto_send(text,numeric,text,text,text) to authenticated;

create or replace function public.submit_withdrawal(p_amount numeric,p_destination text,p_pin text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.accounts; p public.profiles; pin_ok boolean; w public.withdrawals; ref text;
begin
 select * into p from public.profiles where id=auth.uid(); select * into a from public.accounts where user_id=auth.uid() and deleted_at is null limit 1 for update;
 if not found or p.status='deactivated' or p.deleted_at is not null then return jsonb_build_object('success',false,'message','Account unavailable'); end if;
 if a.status='frozen' then return jsonb_build_object('success',false,'message','This account is frozen. Withdrawals are unavailable.'); end if;
 if p_amount is null or p_amount<=0 or trim(p_destination)='' then return jsonb_build_object('success',false,'message','Enter a valid amount and destination.'); end if;
 select transaction_pin_hash is not null and crypt(p_pin,transaction_pin_hash)=transaction_pin_hash into pin_ok from public.profiles where id=auth.uid(); if not coalesce(pin_ok,false) then return jsonb_build_object('success',false,'message','Invalid transaction PIN'); end if;
 if p_amount>a.balance then return jsonb_build_object('success',false,'message','Insufficient available balance.'); end if;
 if a.status='pending' then insert into public.withdrawals(account_id,user_id,amount,currency,destination,status) values(a.id,a.user_id,p_amount,a.currency,trim(p_destination),'pending') returning * into w; insert into public.notifications(user_id,type,title,message) values(a.user_id,'transaction','Withdrawal pending','Your withdrawal is pending because your account is currently pending.'); return jsonb_build_object('success',true,'message','Withdrawal is pending.','withdrawal',to_jsonb(w)); end if;
 a.balance:=a.balance-p_amount; update public.accounts set balance=a.balance where id=a.id; ref:='NXS-WD-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)); insert into public.withdrawals(account_id,user_id,amount,currency,destination,status) values(a.id,a.user_id,p_amount,a.currency,trim(p_destination),'completed') returning * into w; insert into public.transactions(account_id,user_id,type,category,amount,currency,status,description,reference) values(a.id,a.user_id,'withdrawal','customer',p_amount,a.currency,'completed','Withdrawal to '||trim(p_destination),ref); insert into public.notifications(user_id,type,title,message) values(a.user_id,'transaction','Withdrawal completed','Your withdrawal was completed.'); return jsonb_build_object('success',true,'withdrawal',to_jsonb(w),'reference',ref);
end; $$;
grant execute on function public.submit_withdrawal(numeric,text,text) to authenticated;

alter table public.profiles enable row level security;
alter table public.accounts enable row level security;
alter table public.recipient_accounts enable row level security;
alter table public.transactions enable row level security;
alter table public.notifications enable row level security;
alter table public.crypto_transactions enable row level security;
alter table public.deposits enable row level security;
alter table public.withdrawals enable row level security;
alter table public.audit_logs enable row level security;
alter table public.platform_settings enable row level security;

drop policy if exists profiles_self on public.profiles; create policy profiles_self on public.profiles for select to authenticated using(id=auth.uid() or public.is_admin());
drop policy if exists accounts_self on public.accounts; create policy accounts_self on public.accounts for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists recipient_lookup on public.recipient_accounts; create policy recipient_lookup on public.recipient_accounts for select to authenticated using(status='active' or public.is_admin());
drop policy if exists transactions_self on public.transactions; create policy transactions_self on public.transactions for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists notifications_self on public.notifications; create policy notifications_self on public.notifications for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists notifications_update_self on public.notifications; create policy notifications_update_self on public.notifications for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists crypto_self on public.crypto_transactions; create policy crypto_self on public.crypto_transactions for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists deposits_self on public.deposits; create policy deposits_self on public.deposits for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists withdrawals_self on public.withdrawals; create policy withdrawals_self on public.withdrawals for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists audit_admin on public.audit_logs; create policy audit_admin on public.audit_logs for select to authenticated using(public.is_admin());
drop policy if exists settings_public_read on public.platform_settings; create policy settings_public_read on public.platform_settings for select to authenticated using(true);

do $$ begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='notifications') then alter publication supabase_realtime add table public.notifications; end if;
end $$;
