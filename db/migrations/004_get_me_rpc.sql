-- Profile bootstrap RPC for authenticated frontend sessions.

create or replace function public.get_me()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'id', u.id,
    'email', u.email,
    'full_name', u.full_name,
    'role', u.role,
    'organization_id', u.organization_id,
    'organization_name', o.name,
    'organization_status', o.status
  )
  from public.users u
  left join public.organizations o on o.id = u.organization_id
  where u.id = auth.uid()
$$;

revoke all on function public.get_me() from public;
grant execute on function public.get_me() to authenticated;
