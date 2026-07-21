-- Managers see only assigned events (same visibility rule as clients).
-- SuperAdmin / OpsAdmin still see all org events.

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

  -- Org admins can access any event in their org.
  if v_role in ('superadmin', 'opsadmin') then
    return exists (
      select 1 from public.events e
      where e.id = p_event_id
        and e.organization_id = v_org
    );
  end if;

  -- Managers + clients: only events they are assigned to.
  if v_role in ('manager', 'client') then
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

drop policy if exists events_org_roles_read on public.events;
create policy events_org_roles_read
on public.events
for select
using (
  (
    public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
    and organization_id = public.current_auth_organization_id()
  )
  or (
    public.current_auth_role() in ('manager'::public.app_role, 'client'::public.app_role)
    and exists (
      select 1
      from public.event_members em
      where em.event_id = public.events.id
        and em.user_id = auth.uid()
        and em.organization_id = public.current_auth_organization_id()
    )
  )
);
