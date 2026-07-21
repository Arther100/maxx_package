-- Event member assignment + event feed uploads + client event scoping.
-- Additive migration.

create table if not exists public.event_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  member_role public.app_role not null
    check (member_role in ('superadmin', 'opsadmin', 'manager', 'client')),
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  constraint event_members_unique_event_user unique (event_id, user_id)
);

create index if not exists idx_event_members_org on public.event_members(organization_id);
create index if not exists idx_event_members_event on public.event_members(event_id);
create index if not exists idx_event_members_user on public.event_members(user_id);

drop trigger if exists trg_event_members_set_updated_at on public.event_members;
create trigger trg_event_members_set_updated_at
before update on public.event_members
for each row execute function public.set_updated_at();

create table if not exists public.event_uploads (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete cascade,
  uploaded_by uuid references public.users(id) on delete set null,
  upload_type text not null check (upload_type in ('photo', 'video', 'document', 'note')),
  file_url text,
  file_path text,
  caption text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create index if not exists idx_event_uploads_org on public.event_uploads(organization_id);
create index if not exists idx_event_uploads_event on public.event_uploads(event_id);
create index if not exists idx_event_uploads_created_at on public.event_uploads(created_at desc);
create index if not exists idx_event_uploads_uploaded_by on public.event_uploads(uploaded_by);

drop trigger if exists trg_event_uploads_set_updated_at on public.event_uploads;
create trigger trg_event_uploads_set_updated_at
before update on public.event_uploads
for each row execute function public.set_updated_at();

create or replace function public.current_user_in_event(p_event_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.app_role;
  v_org uuid;
begin
  v_role := public.current_auth_role();
  v_org := public.current_auth_organization_id();

  if auth.uid() is null or v_role is null then
    return false;
  end if;

  if public.is_platform_owner_auth() then
    return true;
  end if;

  if v_role in ('superadmin', 'opsadmin', 'manager') then
    return exists (
      select 1 from public.events e
      where e.id = p_event_id
        and e.organization_id = v_org
    );
  end if;

  if v_role = 'client' then
    return exists (
      select 1
      from public.event_members em
      where em.event_id = p_event_id
        and em.user_id = auth.uid()
        and em.organization_id = v_org
    );
  end if;

  return false;
end;
$$;

create or replace function public.can_upload_to_event(p_event_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.app_role;
  v_org uuid;
begin
  v_role := public.current_auth_role();
  v_org := public.current_auth_organization_id();

  if auth.uid() is null or v_role is null then
    return false;
  end if;

  if public.is_platform_owner_auth() then
    return true;
  end if;

  if v_role in ('superadmin', 'opsadmin') then
    return exists (
      select 1 from public.events e
      where e.id = p_event_id
        and e.organization_id = v_org
    );
  end if;

  if v_role = 'manager' then
    return exists (
      select 1
      from public.event_members em
      where em.event_id = p_event_id
        and em.user_id = auth.uid()
        and em.organization_id = v_org
        and em.member_role in ('manager', 'opsadmin', 'superadmin')
    );
  end if;

  return false;
end;
$$;

create or replace function public.event_upload_window_open(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    (e.upload_opens_at is null or now() >= e.upload_opens_at)
    and
    (e.upload_closes_at is null or now() <= e.upload_closes_at)
  from public.events e
  where e.id = p_event_id
$$;

grant execute on function public.current_user_in_event(uuid) to authenticated, service_role;
grant execute on function public.can_upload_to_event(uuid) to authenticated, service_role;
grant execute on function public.event_upload_window_open(uuid) to authenticated, service_role;

alter table public.event_members enable row level security;
alter table public.event_uploads enable row level security;

drop policy if exists event_members_platform_owner_all on public.event_members;
create policy event_members_platform_owner_all
on public.event_members
for all
using (public.is_platform_owner_auth())
with check (public.is_platform_owner_auth());

drop policy if exists event_members_org_admin_read on public.event_members;
create policy event_members_org_admin_read
on public.event_members
for select
using (
  public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);

drop policy if exists event_members_self_read on public.event_members;
create policy event_members_self_read
on public.event_members
for select
using (
  public.has_role_auth(array['manager', 'client']::public.app_role[])
  and user_id = auth.uid()
  and organization_id = public.current_auth_organization_id()
);

drop policy if exists event_members_org_admin_insert on public.event_members;
create policy event_members_org_admin_insert
on public.event_members
for insert
with check (
  public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);

drop policy if exists event_members_org_admin_update on public.event_members;
create policy event_members_org_admin_update
on public.event_members
for update
using (
  public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
)
with check (
  organization_id = public.current_auth_organization_id()
);

drop policy if exists event_members_org_admin_delete on public.event_members;
create policy event_members_org_admin_delete
on public.event_members
for delete
using (
  public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);

drop policy if exists event_uploads_platform_owner_all on public.event_uploads;
create policy event_uploads_platform_owner_all
on public.event_uploads
for all
using (public.is_platform_owner_auth())
with check (public.is_platform_owner_auth());

drop policy if exists event_uploads_event_scope_read on public.event_uploads;
create policy event_uploads_event_scope_read
on public.event_uploads
for select
using (public.current_user_in_event(event_id));

drop policy if exists event_uploads_event_scope_insert on public.event_uploads;
create policy event_uploads_event_scope_insert
on public.event_uploads
for insert
with check (
  organization_id = public.current_auth_organization_id()
  and public.can_upload_to_event(event_id)
  and coalesce(public.event_upload_window_open(event_id), false)
);

drop policy if exists event_uploads_admin_or_owner_update on public.event_uploads;
create policy event_uploads_admin_or_owner_update
on public.event_uploads
for update
using (
  (
    public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
    and organization_id = public.current_auth_organization_id()
  )
  or uploaded_by = auth.uid()
)
with check (
  organization_id = public.current_auth_organization_id()
);

drop policy if exists event_uploads_admin_or_owner_delete on public.event_uploads;
create policy event_uploads_admin_or_owner_delete
on public.event_uploads
for delete
using (
  (
    public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
    and organization_id = public.current_auth_organization_id()
  )
  or uploaded_by = auth.uid()
);

-- Client visibility hardening: clients see only assigned events.
drop policy if exists events_org_roles_read on public.events;
create policy events_org_roles_read
on public.events
for select
using (
  (
    public.has_role_auth(array['superadmin', 'opsadmin', 'manager']::public.app_role[])
    and organization_id = public.current_auth_organization_id()
  )
  or (
    public.current_auth_role() = 'client'::public.app_role
    and exists (
      select 1
      from public.event_members em
      where em.event_id = public.events.id
        and em.user_id = auth.uid()
        and em.organization_id = public.current_auth_organization_id()
    )
  )
);

-- Storage bucket for event uploads (public URLs for lightweight static app).
insert into storage.buckets (id, name, public)
values ('event-uploads', 'event-uploads', true)
on conflict (id) do nothing;

drop policy if exists event_uploads_bucket_insert_authenticated on storage.objects;
create policy event_uploads_bucket_insert_authenticated
on storage.objects
for insert
to authenticated
with check (bucket_id = 'event-uploads');

drop policy if exists event_uploads_bucket_update_authenticated on storage.objects;
create policy event_uploads_bucket_update_authenticated
on storage.objects
for update
to authenticated
using (bucket_id = 'event-uploads')
with check (bucket_id = 'event-uploads');

drop policy if exists event_uploads_bucket_delete_authenticated on storage.objects;
create policy event_uploads_bucket_delete_authenticated
on storage.objects
for delete
to authenticated
using (bucket_id = 'event-uploads');
