-- Supabase Auth + RLS alignment for MAXX SaaS-ready baseline.
-- Additive follow-up migration; keeps existing structures.

-- Keep timestamps fresh on updates.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_users_set_updated_at on public.users;
create trigger trg_users_set_updated_at
before update on public.users
for each row execute function public.set_updated_at();

drop trigger if exists trg_events_set_updated_at on public.events;
create trigger trg_events_set_updated_at
before update on public.events
for each row execute function public.set_updated_at();

-- Normalize email uniqueness for auth mapping by email.
create unique index if not exists ux_users_email_lower on public.users(lower(email));

-- Helper functions based on Supabase auth context.
-- SECURITY DEFINER is used so policies can safely query public.users
-- without recursive RLS evaluation loops.
create or replace function public.current_auth_user_id()
returns uuid
language sql
stable
as $$
  select auth.uid()
$$;

create or replace function public.current_auth_role()
returns public.app_role
language sql
stable
security definer
set search_path = public
as $$
  select u.role
  from public.users u
  where u.id = auth.uid()
$$;

create or replace function public.current_auth_organization_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select u.organization_id
  from public.users u
  where u.id = auth.uid()
$$;

create or replace function public.is_platform_owner_auth()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_auth_role() = 'platform_owner'::public.app_role
$$;

create or replace function public.has_role_auth(allowed public.app_role[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_auth_role() = any(allowed)
$$;

grant execute on function public.current_auth_user_id() to anon, authenticated, service_role;
grant execute on function public.current_auth_role() to anon, authenticated, service_role;
grant execute on function public.current_auth_organization_id() to anon, authenticated, service_role;
grant execute on function public.is_platform_owner_auth() to anon, authenticated, service_role;
grant execute on function public.has_role_auth(public.app_role[]) to anon, authenticated, service_role;

-- Align seeded public.users rows with auth.users IDs when emails match.
-- Run after creating auth users for seed emails.
with auth_matches as (
  select
    pu.id as old_public_id,
    au.id as auth_id
  from public.users pu
  join auth.users au
    on lower(au.email) = lower(pu.email)
  where pu.id <> au.id
    and not exists (
      select 1
      from public.users pu2
      where pu2.id = au.id
    )
)
update public.events e
set created_by = am.auth_id
from auth_matches am
where e.created_by = am.old_public_id;

with auth_matches as (
  select
    pu.id as old_public_id,
    au.id as auth_id
  from public.users pu
  join auth.users au
    on lower(au.email) = lower(pu.email)
  where pu.id <> au.id
    and not exists (
      select 1
      from public.users pu2
      where pu2.id = au.id
    )
)
update public.users u
set id = am.auth_id
from auth_matches am
where u.id = am.old_public_id;

-- Rebuild policies using Supabase auth context + role + organization checks.
drop policy if exists organizations_platform_owner_all on public.organizations;
drop policy if exists organizations_org_scoped_select on public.organizations;

drop policy if exists users_platform_owner_all on public.users;
drop policy if exists users_org_scoped_select on public.users;
drop policy if exists users_org_scoped_insert on public.users;
drop policy if exists users_org_scoped_update on public.users;
drop policy if exists users_org_scoped_delete on public.users;

drop policy if exists events_platform_owner_all on public.events;
drop policy if exists events_org_scoped_select on public.events;
drop policy if exists events_org_scoped_insert on public.events;
drop policy if exists events_org_scoped_update on public.events;
drop policy if exists events_org_scoped_delete on public.events;

-- organizations
create policy organizations_platform_owner_all
on public.organizations
for all
using (public.is_platform_owner_auth())
with check (public.is_platform_owner_auth());

create policy organizations_org_roles_read_own
on public.organizations
for select
using (
  public.has_role_auth(array['superadmin', 'opsadmin', 'manager', 'client']::public.app_role[])
  and id = public.current_auth_organization_id()
);

-- users
create policy users_platform_owner_all
on public.users
for all
using (public.is_platform_owner_auth())
with check (public.is_platform_owner_auth());

create policy users_org_roles_read_own_org
on public.users
for select
using (
  public.has_role_auth(array['superadmin', 'opsadmin', 'manager', 'client']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);

create policy users_org_admin_insert
on public.users
for insert
with check (
  public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
  and role <> 'platform_owner'
  and organization_id = public.current_auth_organization_id()
);

create policy users_org_admin_update
on public.users
for update
using (
  public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
)
with check (
  role <> 'platform_owner'
  and organization_id = public.current_auth_organization_id()
);

create policy users_org_admin_delete
on public.users
for delete
using (
  public.has_role_auth(array['superadmin']::public.app_role[])
  and role <> 'platform_owner'
  and organization_id = public.current_auth_organization_id()
);

-- events
create policy events_platform_owner_all
on public.events
for all
using (public.is_platform_owner_auth())
with check (public.is_platform_owner_auth());

create policy events_org_roles_read
on public.events
for select
using (
  public.has_role_auth(array['superadmin', 'opsadmin', 'manager', 'client']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);

create policy events_org_roles_insert
on public.events
for insert
with check (
  public.has_role_auth(array['superadmin', 'opsadmin', 'manager']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);

create policy events_org_roles_update
on public.events
for update
using (
  public.has_role_auth(array['superadmin', 'opsadmin', 'manager']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
)
with check (
  organization_id = public.current_auth_organization_id()
);

create policy events_org_roles_delete
on public.events
for delete
using (
  public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);
