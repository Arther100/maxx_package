-- Scope event uploads by operation: managers see only their op feed on an event.
-- Clients + admins still see the full event feed.

alter table public.event_uploads
  add column if not exists operation_id uuid references public.operations(id) on delete set null;

create index if not exists idx_event_uploads_operation on public.event_uploads(operation_id);
create index if not exists idx_event_uploads_event_operation on public.event_uploads(event_id, operation_id);

-- Backfill from uploader's event_members row (when available).
update public.event_uploads eu
set operation_id = em.operation_id
from public.event_members em
where eu.operation_id is null
  and em.event_id = eu.event_id
  and em.user_id = eu.uploaded_by
  and em.operation_id is not null;

create or replace function public.can_view_event_upload(p_event_id uuid, p_operation_id uuid)
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

  -- Org admins: full event feed.
  if v_role in ('superadmin', 'opsadmin') then
    return exists (
      select 1 from public.events e
      where e.id = p_event_id
        and e.organization_id = v_org
    );
  end if;

  -- Clients: all uploads on assigned events.
  if v_role = 'client' then
    return exists (
      select 1
      from public.event_members em
      where em.event_id = p_event_id
        and em.user_id = auth.uid()
        and em.organization_id = v_org
        and em.member_role = 'client'
    );
  end if;

  -- Managers: only uploads for their assigned operation on this event.
  if v_role = 'manager' then
    return exists (
      select 1
      from public.event_members em
      where em.event_id = p_event_id
        and em.user_id = auth.uid()
        and em.organization_id = v_org
        and em.member_role = 'manager'
        and em.operation_id is not null
        and em.operation_id = p_operation_id
    );
  end if;

  return false;
end;
$$;

grant execute on function public.can_view_event_upload(uuid, uuid) to authenticated, service_role;

drop policy if exists event_uploads_event_scope_read on public.event_uploads;
create policy event_uploads_event_scope_read
on public.event_uploads
for select
using (public.can_view_event_upload(event_id, operation_id));

-- Managers must insert with their assigned operation_id.
drop policy if exists event_uploads_event_scope_insert on public.event_uploads;
create policy event_uploads_event_scope_insert
on public.event_uploads
for insert
with check (
  organization_id = public.current_auth_organization_id()
  and public.can_upload_to_event(event_id)
  and public.event_upload_window_open(event_id)
  and (
    public.is_platform_owner_auth()
    or public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
    or (
      public.current_auth_role() = 'manager'::public.app_role
      and operation_id is not null
      and exists (
        select 1
        from public.event_members em
        where em.event_id = event_uploads.event_id
          and em.user_id = auth.uid()
          and em.member_role = 'manager'
          and em.operation_id = event_uploads.operation_id
      )
    )
  )
);
