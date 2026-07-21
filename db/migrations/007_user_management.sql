-- User management helpers for admin UI.
-- Links Supabase Auth users into public.users with role + org scope.

create or replace function public.admin_link_org_user(
  p_email text,
  p_full_name text,
  p_role public.app_role
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_role public.app_role;
  v_caller_org uuid;
  v_auth_id uuid;
  v_auth_email text;
  v_org uuid;
  v_existing_id uuid;
  v_row public.users;
begin
  v_caller_role := public.current_auth_role();
  v_caller_org := public.current_auth_organization_id();

  if auth.uid() is null or v_caller_role is null then
    raise exception 'Not authenticated';
  end if;

  if v_caller_role not in ('platform_owner', 'superadmin', 'opsadmin') then
    raise exception 'Not allowed to manage users';
  end if;

  if p_email is null or trim(p_email) = '' then
    raise exception 'Email is required';
  end if;

  if p_role is null then
    raise exception 'Role is required';
  end if;

  if p_role = 'platform_owner' and v_caller_role <> 'platform_owner' then
    raise exception 'Only platform_owner can assign platform_owner';
  end if;

  if v_caller_role = 'opsadmin' and p_role in ('superadmin', 'platform_owner') then
    raise exception 'OpsAdmin cannot assign superadmin or platform_owner';
  end if;

  if p_role = 'platform_owner' then
    v_org := null;
  elsif v_caller_role = 'platform_owner' then
    select o.id into v_org
    from public.organizations o
    where o.name = 'MAXX Events'
    limit 1;
  else
    v_org := v_caller_org;
  end if;

  if p_role <> 'platform_owner' and v_org is null then
    raise exception 'Organization required for role %', p_role;
  end if;

  select au.id, au.email
  into v_auth_id, v_auth_email
  from auth.users au
  where lower(au.email) = lower(trim(p_email))
  limit 1;

  if v_auth_id is null then
    raise exception
      'No Auth user found for %. Create the user first in Supabase → Authentication → Users (Add user), then link the profile here.',
      trim(p_email);
  end if;

  select u.id
  into v_existing_id
  from public.users u
  where lower(u.email) = lower(trim(p_email))
    and u.id <> v_auth_id
  limit 1;

  if v_existing_id is not null then
    raise exception
      'A public.users row already exists for % with a different id. Run auth ID alignment or remove the orphan profile first.',
      trim(p_email);
  end if;

  insert into public.users (id, email, full_name, role, organization_id)
  values (
    v_auth_id,
    v_auth_email,
    nullif(trim(coalesce(p_full_name, '')), ''),
    p_role,
    v_org
  )
  on conflict (id) do update
  set
    email = excluded.email,
    full_name = excluded.full_name,
    role = excluded.role,
    organization_id = excluded.organization_id,
    updated_at = now()
  returning * into v_row;

  return json_build_object(
    'id', v_row.id,
    'email', v_row.email,
    'full_name', v_row.full_name,
    'role', v_row.role,
    'organization_id', v_row.organization_id
  );
end;
$$;

create or replace function public.admin_update_org_user(
  p_user_id uuid,
  p_full_name text,
  p_role public.app_role
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_role public.app_role;
  v_caller_org uuid;
  v_target public.users;
  v_row public.users;
begin
  v_caller_role := public.current_auth_role();
  v_caller_org := public.current_auth_organization_id();

  if auth.uid() is null or v_caller_role is null then
    raise exception 'Not authenticated';
  end if;

  if v_caller_role not in ('platform_owner', 'superadmin', 'opsadmin') then
    raise exception 'Not allowed to manage users';
  end if;

  select * into v_target
  from public.users u
  where u.id = p_user_id;

  if v_target.id is null then
    raise exception 'User not found';
  end if;

  if v_caller_role <> 'platform_owner'
     and v_target.organization_id is distinct from v_caller_org then
    raise exception 'Cannot manage users outside your organization';
  end if;

  if v_target.role = 'platform_owner' and v_caller_role <> 'platform_owner' then
    raise exception 'Cannot modify platform_owner';
  end if;

  if p_role = 'platform_owner' and v_caller_role <> 'platform_owner' then
    raise exception 'Only platform_owner can assign platform_owner';
  end if;

  if v_caller_role = 'opsadmin' and p_role in ('superadmin', 'platform_owner') then
    raise exception 'OpsAdmin cannot assign superadmin or platform_owner';
  end if;

  if v_caller_role = 'opsadmin' and v_target.role = 'superadmin' then
    raise exception 'OpsAdmin cannot modify superadmin';
  end if;

  update public.users u
  set
    full_name = nullif(trim(coalesce(p_full_name, '')), ''),
    role = p_role,
    organization_id = case
      when p_role = 'platform_owner' then null
      else coalesce(u.organization_id, v_caller_org)
    end,
    updated_at = now()
  where u.id = p_user_id
  returning * into v_row;

  return json_build_object(
    'id', v_row.id,
    'email', v_row.email,
    'full_name', v_row.full_name,
    'role', v_row.role,
    'organization_id', v_row.organization_id
  );
end;
$$;

revoke all on function public.admin_link_org_user(text, text, public.app_role) from public;
revoke all on function public.admin_update_org_user(uuid, text, public.app_role) from public;
grant execute on function public.admin_link_org_user(text, text, public.app_role) to authenticated;
grant execute on function public.admin_update_org_user(uuid, text, public.app_role) to authenticated;
