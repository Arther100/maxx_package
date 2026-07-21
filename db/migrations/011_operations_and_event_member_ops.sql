-- Event operations (decor, food, photography, …) + link on event_members.
-- Run after 010.

create table if not exists public.operations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  name text not null,
  code text,
  description text,
  sort_order int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  constraint operations_org_name_unique unique (organization_id, name)
);

create index if not exists idx_operations_org on public.operations(organization_id);
create index if not exists idx_operations_active on public.operations(organization_id, is_active);

drop trigger if exists trg_operations_set_updated_at on public.operations;
create trigger trg_operations_set_updated_at
before update on public.operations
for each row execute function public.set_updated_at();

alter table public.event_members
  add column if not exists operation_id uuid references public.operations(id) on delete set null;

create index if not exists idx_event_members_operation on public.event_members(operation_id);

-- Seed default operations for MAXX Events (idempotent).
insert into public.operations (organization_id, name, code, sort_order, description)
select o.id, s.name, s.code, s.sort_order, s.description
from public.organizations o
cross join (
  values
    ('Decor', 'decor', 10, 'Stage, floral, and venue décor'),
    ('Food & Catering', 'food', 20, 'Catering and F&B'),
    ('Photography', 'photography', 30, 'Photo coverage'),
    ('Videography', 'videography', 40, 'Video coverage'),
    ('Makeup', 'makeup', 50, 'Makeup and styling'),
    ('Music / DJ', 'music', 60, 'Music and entertainment'),
    ('Logistics', 'logistics', 70, 'Transport and coordination'),
    ('General', 'general', 100, 'General event operations')
) as s(name, code, sort_order, description)
where o.name = 'MAXX Events'
on conflict (organization_id, name) do nothing;

alter table public.operations enable row level security;

drop policy if exists operations_platform_owner_all on public.operations;
create policy operations_platform_owner_all
on public.operations
for all
using (public.is_platform_owner_auth())
with check (public.is_platform_owner_auth());

drop policy if exists operations_org_admin_all on public.operations;
create policy operations_org_admin_all
on public.operations
for all
using (
  public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
)
with check (
  public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);

drop policy if exists operations_org_read on public.operations;
create policy operations_org_read
on public.operations
for select
using (
  public.has_role_auth(array['manager', 'client']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
  and is_active = true
);
