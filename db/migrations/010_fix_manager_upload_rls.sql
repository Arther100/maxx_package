-- Fix manager upload RLS: assigned managers can post; upload window defaults open.

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

  -- Org admins can upload to any event in their org.
  if v_role in ('superadmin', 'opsadmin') then
    return exists (
      select 1 from public.events e
      where e.id = p_event_id
        and e.organization_id = v_org
    );
  end if;

  -- Managers: must be assigned to the event (any assignment row).
  if v_role = 'manager' then
    return exists (
      select 1
      from public.event_members em
      where em.event_id = p_event_id
        and em.user_id = auth.uid()
        and em.organization_id = v_org
        and em.member_role = 'manager'
    );
  end if;

  return false;
end;
$$;

-- Default open when dates are null / event missing; only block outside window.
create or replace function public.event_upload_window_open(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select
        (e.upload_opens_at is null or now() >= e.upload_opens_at)
        and
        (e.upload_closes_at is null or now() <= e.upload_closes_at)
      from public.events e
      where e.id = p_event_id
    ),
    true
  );
$$;

drop policy if exists event_uploads_event_scope_insert on public.event_uploads;
create policy event_uploads_event_scope_insert
on public.event_uploads
for insert
with check (
  organization_id = public.current_auth_organization_id()
  and public.can_upload_to_event(event_id)
  and public.event_upload_window_open(event_id)
);
