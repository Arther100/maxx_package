-- MAXX Events SaaS-ready foundation
-- This migration is additive and does not remove existing structures.

-- Required for gen_random_uuid().
create extension if not exists pgcrypto;

-- Core organizations table (single org today, multi-org ready later).
create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  status text check (status in ('active', 'inactive')) default 'active',
  created_at timestamptz default now()
);

-- Platform + organization-scoped role model.
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'app_role'
      and n.nspname = 'public'
  ) then
    create type public.app_role as enum (
      'platform_owner',
      'superadmin',
      'opsadmin',
      'manager',
      'client'
    );
  end if;
end $$;

-- Users table with org scoping. platform_owner is org-agnostic.
create table if not exists public.users (
  id uuid primary key default gen_random_uuid(),
  email text unique not null,
  full_name text,
  role public.app_role not null,
  organization_id uuid references public.organizations(id) on delete restrict,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  constraint users_platform_owner_org_null_chk
    check (
      (role = 'platform_owner' and organization_id is null)
      or
      (role <> 'platform_owner' and organization_id is not null)
    )
);

-- Events table with mandatory organization ownership.
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  title text not null,
  event_date date,
  status text default 'draft',
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create index if not exists idx_users_organization_id on public.users(organization_id);
create index if not exists idx_events_organization_id on public.events(organization_id);

-- App context helpers (set these per request/session in backend).
create or replace function public.current_user_id()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('app.current_user_id', true), '')::uuid
$$;

create or replace function public.current_user_role()
returns public.app_role
language sql
stable
as $$
  select nullif(current_setting('app.current_user_role', true), '')::public.app_role
$$;

create or replace function public.current_organization_id()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('app.current_organization_id', true), '')::uuid
$$;

create or replace function public.is_platform_owner()
returns boolean
language sql
stable
as $$
  select public.current_user_role() = 'platform_owner'::public.app_role
$$;

-- Enable RLS and enforce org-scoped access for non-platform owners.
alter table public.organizations enable row level security;
alter table public.users enable row level security;
alter table public.events enable row level security;

-- Organizations:
-- - platform_owner: full access
-- - others: only their own org row
drop policy if exists organizations_platform_owner_all on public.organizations;
create policy organizations_platform_owner_all
on public.organizations
for all
using (public.is_platform_owner())
with check (public.is_platform_owner());

drop policy if exists organizations_org_scoped_select on public.organizations;
create policy organizations_org_scoped_select
on public.organizations
for select
using (
  not public.is_platform_owner()
  and id = public.current_organization_id()
);

-- Users:
-- - platform_owner: full access
-- - others: org-scoped only
drop policy if exists users_platform_owner_all on public.users;
create policy users_platform_owner_all
on public.users
for all
using (public.is_platform_owner())
with check (public.is_platform_owner());

drop policy if exists users_org_scoped_select on public.users;
create policy users_org_scoped_select
on public.users
for select
using (
  not public.is_platform_owner()
  and organization_id = public.current_organization_id()
);

drop policy if exists users_org_scoped_insert on public.users;
create policy users_org_scoped_insert
on public.users
for insert
with check (
  not public.is_platform_owner()
  and organization_id = public.current_organization_id()
  and role <> 'platform_owner'
);

drop policy if exists users_org_scoped_update on public.users;
create policy users_org_scoped_update
on public.users
for update
using (
  not public.is_platform_owner()
  and organization_id = public.current_organization_id()
)
with check (
  organization_id = public.current_organization_id()
  and role <> 'platform_owner'
);

drop policy if exists users_org_scoped_delete on public.users;
create policy users_org_scoped_delete
on public.users
for delete
using (
  not public.is_platform_owner()
  and organization_id = public.current_organization_id()
  and role <> 'platform_owner'
);

-- Events:
-- - platform_owner: full access
-- - others: org-scoped only
drop policy if exists events_platform_owner_all on public.events;
create policy events_platform_owner_all
on public.events
for all
using (public.is_platform_owner())
with check (public.is_platform_owner());

drop policy if exists events_org_scoped_select on public.events;
create policy events_org_scoped_select
on public.events
for select
using (
  not public.is_platform_owner()
  and organization_id = public.current_organization_id()
);

drop policy if exists events_org_scoped_insert on public.events;
create policy events_org_scoped_insert
on public.events
for insert
with check (
  not public.is_platform_owner()
  and organization_id = public.current_organization_id()
);

drop policy if exists events_org_scoped_update on public.events;
create policy events_org_scoped_update
on public.events
for update
using (
  not public.is_platform_owner()
  and organization_id = public.current_organization_id()
)
with check (
  organization_id = public.current_organization_id()
);

drop policy if exists events_org_scoped_delete on public.events;
create policy events_org_scoped_delete
on public.events
for delete
using (
  not public.is_platform_owner()
  and organization_id = public.current_organization_id()
);

-- Seed data expected by requirement:
-- - MAXX Events organization
-- - one platform_owner (organization_id = null)
-- - one superadmin scoped to MAXX Events org
with upsert_org as (
  insert into public.organizations (name, status)
  values ('MAXX Events', 'active')
  on conflict do nothing
  returning id
),
maxx_org as (
  select id from upsert_org
  union all
  select id from public.organizations where name = 'MAXX Events' limit 1
)
insert into public.users (email, full_name, role, organization_id)
select 'platform.owner@maxxevents.local', 'Platform Owner', 'platform_owner', null
where not exists (
  select 1 from public.users where email = 'platform.owner@maxxevents.local'
);

with maxx_org as (
  select id from public.organizations where name = 'MAXX Events' limit 1
)
insert into public.users (email, full_name, role, organization_id)
select 'superadmin@maxxevents.local', 'MAXX SuperAdmin', 'superadmin', id
from maxx_org
where not exists (
  select 1 from public.users where email = 'superadmin@maxxevents.local'
);
