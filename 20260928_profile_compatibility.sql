-- NEXUS profile compatibility migration
-- Aligns the current profiles table (which already has is_active)
-- with the NEXUS backend functions that also use status/deleted_at.
-- Safe to run more than once.

alter table public.profiles
  add column if not exists status text;

alter table public.profiles
  add column if not exists deleted_at timestamptz;

-- Keep the two activity representations synchronized.
update public.profiles
set status = case when coalesce(is_active,true) then 'active' else 'deactivated' end
where status is null;

alter table public.profiles
  alter column status set default 'active';

-- Prevent invalid profile status values.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_status_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_status_check
      check (status in ('active','deactivated'));
  end if;
end $$;

create or replace function public.sync_nexus_profile_activity()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    if new.status is null then
      new.status := case when coalesce(new.is_active,true) then 'active' else 'deactivated' end;
    end if;
    if new.is_active is null then
      new.is_active := (new.status = 'active');
    end if;
    return new;
  end if;

  if new.status is distinct from old.status then
    new.is_active := (new.status = 'active');
  elsif new.is_active is distinct from old.is_active then
    new.status := case when coalesce(new.is_active,true) then 'active' else 'deactivated' end;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_nexus_profile_activity on public.profiles;
create trigger trg_sync_nexus_profile_activity
before insert or update of status, is_active on public.profiles
for each row
execute function public.sync_nexus_profile_activity();

-- Verify the administrator profile after the Auth user has been created.
select id,email,full_name,phone,role,is_active,status,deleted_at,created_at,updated_at
from public.profiles
where email = 'deanlewis1x@gmail.com';
