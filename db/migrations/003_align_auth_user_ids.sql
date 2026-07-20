-- Fix public.users <-> auth.users ID alignment by email.
-- Safe to run multiple times.
-- Run in Supabase SQL Editor after auth users exist.
-- Uses SECURITY DEFINER so it works even when RLS is enabled.

create or replace function public.align_seed_users_to_auth()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_platform_full_name text;
  v_super_full_name text;
  v_super_org_id uuid;
begin
  select pu.full_name
  into v_platform_full_name
  from public.users pu
  where lower(pu.email) = 'platform.owner@maxxevents.local'
  limit 1;

  select pu.full_name, pu.organization_id
  into v_super_full_name, v_super_org_id
  from public.users pu
  where lower(pu.email) = 'superadmin@maxxevents.local'
  limit 1;

  if v_super_org_id is null then
    select o.id
    into v_super_org_id
    from public.organizations o
    where o.name = 'MAXX Events'
    limit 1;
  end if;

  update public.events e
  set created_by = au.id
  from public.users pu
  join auth.users au on lower(au.email) = lower(pu.email)
  where e.created_by = pu.id
    and pu.id <> au.id;

  delete from public.users pu
  using auth.users au
  where lower(pu.email) = lower(au.email)
    and pu.id <> au.id;

  insert into public.users (id, email, full_name, role, organization_id)
  select
    au.id,
    au.email,
    coalesce(v_platform_full_name, 'Platform Owner'),
    'platform_owner'::public.app_role,
    null::uuid
  from auth.users au
  where lower(au.email) = 'platform.owner@maxxevents.local'
  on conflict (id) do update
  set
    email = excluded.email,
    full_name = excluded.full_name,
    role = excluded.role,
    organization_id = excluded.organization_id;

  insert into public.users (id, email, full_name, role, organization_id)
  select
    au.id,
    au.email,
    coalesce(v_super_full_name, 'MAXX SuperAdmin'),
    'superadmin'::public.app_role,
    v_super_org_id
  from auth.users au
  where lower(au.email) = 'superadmin@maxxevents.local'
  on conflict (id) do update
  set
    email = excluded.email,
    full_name = excluded.full_name,
    role = excluded.role,
    organization_id = excluded.organization_id;
end;
$$;

revoke all on function public.align_seed_users_to_auth() from public;
grant execute on function public.align_seed_users_to_auth() to service_role;

select public.align_seed_users_to_auth();
