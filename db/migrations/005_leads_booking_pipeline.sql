-- Priority 6/7: leads pipeline for booking form + admin leads dashboard.
-- Additive migration. Keeps existing tables/policies.

create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  quote_code text not null,
  name text not null,
  phone text not null,
  person_name text,
  event_type text,
  event_date date,
  location text,
  venue_type text,
  venue_note text,
  budget text,
  services_count integer default 0,
  non_veg_count text,
  veg_count text,
  notes text,
  veg_menus jsonb default '{}'::jsonb,
  services jsonb default '{}'::jsonb,
  status text not null default 'New'
    check (status in ('New', 'Contacted', 'Quoted', 'Confirmed', 'Cancelled')),
  source text default 'form',
  submitted_at timestamptz default now(),
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  constraint leads_quote_code_org_unique unique (organization_id, quote_code)
);

create index if not exists idx_leads_organization_id on public.leads(organization_id);
create index if not exists idx_leads_status on public.leads(status);
create index if not exists idx_leads_submitted_at on public.leads(submitted_at desc);
create index if not exists idx_leads_quote_code on public.leads(quote_code);

drop trigger if exists trg_leads_set_updated_at on public.leads;
create trigger trg_leads_set_updated_at
before update on public.leads
for each row execute function public.set_updated_at();

alter table public.leads enable row level security;

drop policy if exists leads_platform_owner_all on public.leads;
create policy leads_platform_owner_all
on public.leads
for all
using (public.is_platform_owner_auth())
with check (public.is_platform_owner_auth());

drop policy if exists leads_org_roles_read on public.leads;
create policy leads_org_roles_read
on public.leads
for select
using (
  public.has_role_auth(array['superadmin', 'opsadmin', 'manager']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);

drop policy if exists leads_org_roles_insert on public.leads;
create policy leads_org_roles_insert
on public.leads
for insert
with check (
  public.has_role_auth(array['superadmin', 'opsadmin', 'manager']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);

drop policy if exists leads_org_roles_update on public.leads;
create policy leads_org_roles_update
on public.leads
for update
using (
  public.has_role_auth(array['superadmin', 'opsadmin', 'manager']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
)
with check (
  organization_id = public.current_auth_organization_id()
);

drop policy if exists leads_org_roles_delete on public.leads;
create policy leads_org_roles_delete
on public.leads
for delete
using (
  public.has_role_auth(array['superadmin', 'opsadmin']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);

-- Public booking form insert (anon). Always scopes to MAXX Events org.
create or replace function public.create_public_lead(payload jsonb)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_quote text;
  v_row public.leads;
  v_event_date date;
begin
  select o.id
  into v_org_id
  from public.organizations o
  where o.name = 'MAXX Events'
    and coalesce(o.status, 'active') = 'active'
  limit 1;

  if v_org_id is null then
    raise exception 'MAXX Events organization not found';
  end if;

  v_quote := nullif(trim(coalesce(payload->>'quote_code', payload->>'quoteCode', '')), '');
  if v_quote is null then
    raise exception 'quote_code is required';
  end if;

  if nullif(trim(coalesce(payload->>'name', '')), '') is null then
    raise exception 'name is required';
  end if;

  if nullif(trim(coalesce(payload->>'phone', '')), '') is null then
    raise exception 'phone is required';
  end if;

  begin
    v_event_date := nullif(trim(coalesce(payload->>'event_date', payload->>'date', '')), '')::date;
  exception when others then
    v_event_date := null;
  end;

  insert into public.leads (
    organization_id,
    quote_code,
    name,
    phone,
    person_name,
    event_type,
    event_date,
    location,
    venue_type,
    venue_note,
    budget,
    services_count,
    non_veg_count,
    veg_count,
    notes,
    veg_menus,
    services,
    status,
    source,
    submitted_at
  )
  values (
    v_org_id,
    v_quote,
    trim(payload->>'name'),
    trim(payload->>'phone'),
    nullif(trim(coalesce(payload->>'person_name', payload->>'personName', '')), ''),
    nullif(trim(coalesce(payload->>'event_type', payload->>'eventType', '')), ''),
    v_event_date,
    nullif(trim(coalesce(payload->>'location', '')), ''),
    nullif(trim(coalesce(payload->>'venue_type', payload->>'venueType', '')), ''),
    nullif(trim(coalesce(payload->>'venue_note', payload->>'venueNote', payload->>'venueName', '')), ''),
    nullif(trim(coalesce(payload->>'budget', '')), ''),
    coalesce((payload->>'services_count')::int, (payload->>'servicesCount')::int, 0),
    nullif(trim(coalesce(payload->>'non_veg_count', payload->>'nonVegCount', '')), ''),
    nullif(trim(coalesce(payload->>'veg_count', payload->>'vegCount', '')), ''),
    nullif(trim(coalesce(payload->>'notes', '')), ''),
    coalesce(payload->'veg_menus', payload->'vegMenus', '{}'::jsonb),
    coalesce(payload->'services', '{}'::jsonb),
    coalesce(nullif(trim(coalesce(payload->>'status', '')), ''), 'New'),
    coalesce(nullif(trim(coalesce(payload->>'source', '')), ''), 'form'),
    coalesce((payload->>'submitted_at')::timestamptz, now())
  )
  on conflict (organization_id, quote_code) do update
  set
    name = excluded.name,
    phone = excluded.phone,
    person_name = excluded.person_name,
    event_type = excluded.event_type,
    event_date = excluded.event_date,
    location = excluded.location,
    venue_type = excluded.venue_type,
    venue_note = excluded.venue_note,
    budget = excluded.budget,
    services_count = excluded.services_count,
    non_veg_count = excluded.non_veg_count,
    veg_count = excluded.veg_count,
    notes = excluded.notes,
    veg_menus = excluded.veg_menus,
    services = excluded.services,
    source = excluded.source,
    updated_at = now()
  returning * into v_row;

  return json_build_object(
    'id', v_row.id,
    'quote_code', v_row.quote_code,
    'organization_id', v_row.organization_id,
    'status', v_row.status
  );
end;
$$;

revoke all on function public.create_public_lead(jsonb) from public;
grant execute on function public.create_public_lead(jsonb) to anon, authenticated;
