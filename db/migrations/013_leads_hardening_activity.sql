-- 013: Leads hardening + activity log + WhatsApp message log.
-- Additive and safe to re-run. Run AFTER 001-012 in the Supabase SQL editor.
--
-- Fixes:
--   * Public form can no longer overwrite an existing lead (quote codes are
--     generated on the server, unique per organization, never upserted by anon).
--   * Public form can no longer choose its own status/source (always New/form).
--   * Phone numbers are validated and normalised (India +91 added to 10-digit numbers).
--   * Basic spam guard (per-phone and global rate limits) + length caps.
--   * Adds lead_activity (status history, WhatsApp messages sent, notes).
--   * Enables realtime for leads + lead_activity.

-- ---------------------------------------------------------------------------
-- 1. Columns / indexes
-- ---------------------------------------------------------------------------
alter table public.leads add column if not exists phone_e164 text;
alter table public.leads add column if not exists last_contacted_at timestamptz;

create index if not exists idx_leads_event_date on public.leads(event_date);
create index if not exists idx_leads_phone_e164 on public.leads(phone_e164);

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------

-- Digits-only phone with country code. Returns null when it cannot be valid.
--   9876543210    -> 919876543210
--   09876543210   -> 919876543210
--   +91 98765 43210 / 919876543210 / 0091... -> 919876543210
--   Other international numbers with 11-15 digits are kept as typed.
create or replace function public.normalize_phone_in(p_phone text)
returns text
language sql
immutable
as $$
  with s as (
    select regexp_replace(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '^00', '') as d
  )
  select case
    when d = '' then null
    when length(d) = 10 and d ~ '^[6-9]' then '91' || d
    when length(d) = 11 and d ~ '^0[6-9]' then '91' || substr(d, 2)
    when length(d) between 11 and 15 and d !~ '^0' then d
    else null
  end
  from s
$$;

-- Server-side quote code: MX + IST date (YYMMDD) + '-' + 4 unambiguous chars.
create or replace function public.gen_lead_quote_code(p_org uuid)
returns text
language plpgsql
volatile
set search_path = public
as $$
declare
  v_chars constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text;
  v_try int := 0;
  v_suffix text;
  i int;
begin
  loop
    v_suffix := '';
    for i in 1..4 loop
      v_suffix := v_suffix || substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1);
    end loop;
    v_code := 'MX' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-' || v_suffix;
    exit when not exists (
      select 1 from public.leads l
      where l.organization_id = p_org and l.quote_code = v_code
    );
    v_try := v_try + 1;
    if v_try > 20 then
      raise exception 'could_not_generate_quote_code';
    end if;
  end loop;
  return v_code;
end;
$$;

revoke all on function public.gen_lead_quote_code(uuid) from public;

create or replace function public.safe_int(p_text text, p_default int default 0)
returns int
language sql
immutable
as $$
  select case when p_text ~ '^\d{1,6}$' then p_text::int else p_default end
$$;

-- ---------------------------------------------------------------------------
-- 3. Activity log
-- ---------------------------------------------------------------------------
create table if not exists public.lead_activity (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.leads(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  kind text not null check (kind in ('created', 'status_change', 'whatsapp', 'note', 'call')),
  from_status text,
  to_status text,
  template text,
  message text,
  note text,
  created_by uuid,
  created_by_email text,
  created_at timestamptz not null default now()
);

create index if not exists idx_lead_activity_lead on public.lead_activity(lead_id, created_at desc);
create index if not exists idx_lead_activity_org on public.lead_activity(organization_id);

alter table public.lead_activity enable row level security;

drop policy if exists lead_activity_platform_owner_all on public.lead_activity;
create policy lead_activity_platform_owner_all
on public.lead_activity
for all
using (public.is_platform_owner_auth())
with check (public.is_platform_owner_auth());

drop policy if exists lead_activity_org_read on public.lead_activity;
create policy lead_activity_org_read
on public.lead_activity
for select
using (
  public.has_role_auth(array['superadmin', 'opsadmin', 'manager']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);

drop policy if exists lead_activity_org_insert on public.lead_activity;
create policy lead_activity_org_insert
on public.lead_activity
for insert
with check (
  public.has_role_auth(array['superadmin', 'opsadmin', 'manager']::public.app_role[])
  and organization_id = public.current_auth_organization_id()
);

-- Log creation + status changes automatically.
create or replace function public.trg_leads_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
begin
  select u.email into v_email from public.users u where u.id = auth.uid();

  if tg_op = 'INSERT' then
    insert into public.lead_activity (lead_id, organization_id, kind, to_status, created_by, created_by_email)
    values (new.id, new.organization_id, 'created', new.status, auth.uid(), v_email);
  elsif tg_op = 'UPDATE' and new.status is distinct from old.status then
    insert into public.lead_activity (lead_id, organization_id, kind, from_status, to_status, created_by, created_by_email)
    values (new.id, new.organization_id, 'status_change', old.status, new.status, auth.uid(), v_email);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_leads_activity_ins on public.leads;
create trigger trg_leads_activity_ins
after insert on public.leads
for each row execute function public.trg_leads_activity();

drop trigger if exists trg_leads_activity_upd on public.leads;
create trigger trg_leads_activity_upd
after update of status on public.leads
for each row execute function public.trg_leads_activity();

-- Keep phone_e164 in sync on every insert/update.
create or replace function public.trg_leads_phone()
returns trigger
language plpgsql
as $$
begin
  new.phone_e164 := public.normalize_phone_in(new.phone);
  return new;
end;
$$;

drop trigger if exists trg_leads_phone on public.leads;
create trigger trg_leads_phone
before insert or update of phone on public.leads
for each row execute function public.trg_leads_phone();

-- Backfill existing rows.
update public.leads set phone_e164 = public.normalize_phone_in(phone) where phone_e164 is null;

-- ---------------------------------------------------------------------------
-- 4. Public booking form RPC (anon) - hardened
-- ---------------------------------------------------------------------------
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
  v_name text;
  v_phone text;
  v_e164 text;
begin
  select o.id into v_org_id
  from public.organizations o
  where o.name = 'MAXX Events' and coalesce(o.status, 'active') = 'active'
  limit 1;

  if v_org_id is null then
    raise exception 'MAXX Events organization not found';
  end if;

  v_name := left(trim(coalesce(payload->>'name', '')), 100);
  v_phone := left(trim(coalesce(payload->>'phone', '')), 30);

  if length(v_name) < 2 then
    raise exception 'invalid_name';
  end if;

  v_e164 := public.normalize_phone_in(v_phone);
  if v_e164 is null then
    raise exception 'invalid_phone';
  end if;

  -- Spam guard: same phone max 5 per hour, whole form max 60 per minute.
  if (select count(*) from public.leads l
      where l.organization_id = v_org_id and l.phone_e164 = v_e164
        and l.created_at > now() - interval '1 hour') >= 5 then
    raise exception 'rate_limited';
  end if;

  if (select count(*) from public.leads l
      where l.organization_id = v_org_id and l.source = 'form'
        and l.created_at > now() - interval '1 minute') >= 60 then
    raise exception 'rate_limited';
  end if;

  begin
    v_event_date := nullif(trim(coalesce(payload->>'event_date', payload->>'date', '')), '')::date;
  exception when others then
    v_event_date := null;
  end;

  v_quote := public.gen_lead_quote_code(v_org_id);

  insert into public.leads (
    organization_id, quote_code, name, phone, person_name, event_type, event_date,
    location, venue_type, venue_note, budget, services_count, non_veg_count,
    veg_count, notes, veg_menus, services, status, source, submitted_at
  )
  values (
    v_org_id,
    v_quote,
    v_name,
    v_phone,
    left(nullif(trim(coalesce(payload->>'person_name', payload->>'personName', '')), ''), 100),
    left(nullif(trim(coalesce(payload->>'event_type', payload->>'eventType', '')), ''), 100),
    v_event_date,
    left(nullif(trim(coalesce(payload->>'location', '')), ''), 200),
    left(nullif(trim(coalesce(payload->>'venue_type', payload->>'venueType', '')), ''), 100),
    left(nullif(trim(coalesce(payload->>'venue_note', payload->>'venueNote', payload->>'venueName', '')), ''), 200),
    left(nullif(trim(coalesce(payload->>'budget', '')), ''), 60),
    public.safe_int(coalesce(payload->>'services_count', payload->>'servicesCount'), 0),
    left(nullif(trim(coalesce(payload->>'non_veg_count', payload->>'nonVegCount', '')), ''), 20),
    left(nullif(trim(coalesce(payload->>'veg_count', payload->>'vegCount', '')), ''), 20),
    left(nullif(trim(coalesce(payload->>'notes', '')), ''), 4000),
    case when jsonb_typeof(coalesce(payload->'veg_menus', payload->'vegMenus')) = 'object'
         then coalesce(payload->'veg_menus', payload->'vegMenus') else '{}'::jsonb end,
    case when jsonb_typeof(payload->'services') = 'object' then payload->'services' else '{}'::jsonb end,
    'New',
    'form',
    now()
  )
  returning * into v_row;

  return json_build_object(
    'id', v_row.id,
    'quote_code', v_row.quote_code,
    'status', v_row.status
  );
end;
$$;

revoke all on function public.create_public_lead(jsonb) from public;
grant execute on function public.create_public_lead(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Admin save RPC (manual entry + import). Upsert allowed, roles checked.
-- ---------------------------------------------------------------------------
create or replace function public.admin_save_lead(payload jsonb)
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
  v_status text;
  v_source text;
  v_phone text;
begin
  if not public.has_role_auth(array['platform_owner', 'superadmin', 'opsadmin']::public.app_role[]) then
    raise exception 'not_allowed';
  end if;

  v_org_id := public.current_auth_organization_id();
  if v_org_id is null then
    select o.id into v_org_id from public.organizations o where o.name = 'MAXX Events' limit 1;
  end if;
  if v_org_id is null then
    raise exception 'organization_not_found';
  end if;

  v_phone := left(trim(coalesce(payload->>'phone', '')), 30);
  if public.normalize_phone_in(v_phone) is null then
    raise exception 'invalid_phone';
  end if;
  if length(trim(coalesce(payload->>'name', ''))) < 2 then
    raise exception 'invalid_name';
  end if;

  v_quote := nullif(trim(coalesce(payload->>'quote_code', payload->>'quoteCode', '')), '');
  if v_quote is null then
    v_quote := public.gen_lead_quote_code(v_org_id);
  end if;

  v_status := coalesce(nullif(trim(coalesce(payload->>'status', '')), ''), 'New');
  if v_status not in ('New', 'Contacted', 'Quoted', 'Confirmed', 'Cancelled') then
    v_status := 'New';
  end if;

  v_source := coalesce(nullif(trim(coalesce(payload->>'source', '')), ''), 'manual');
  if v_source not in ('form', 'manual', 'import', 'whatsapp') then
    v_source := 'manual';
  end if;

  begin
    v_event_date := nullif(trim(coalesce(payload->>'event_date', payload->>'date', '')), '')::date;
  exception when others then
    v_event_date := null;
  end;

  insert into public.leads (
    organization_id, quote_code, name, phone, person_name, event_type, event_date,
    location, venue_type, venue_note, budget, services_count, non_veg_count,
    veg_count, notes, veg_menus, services, status, source, submitted_at
  )
  values (
    v_org_id,
    v_quote,
    left(trim(payload->>'name'), 100),
    v_phone,
    left(nullif(trim(coalesce(payload->>'person_name', payload->>'personName', '')), ''), 100),
    left(nullif(trim(coalesce(payload->>'event_type', payload->>'eventType', '')), ''), 100),
    v_event_date,
    left(nullif(trim(coalesce(payload->>'location', '')), ''), 200),
    left(nullif(trim(coalesce(payload->>'venue_type', payload->>'venueType', '')), ''), 100),
    left(nullif(trim(coalesce(payload->>'venue_note', payload->>'venueNote', payload->>'venueName', '')), ''), 200),
    left(nullif(trim(coalesce(payload->>'budget', '')), ''), 60),
    public.safe_int(coalesce(payload->>'services_count', payload->>'servicesCount'), 0),
    left(nullif(trim(coalesce(payload->>'non_veg_count', payload->>'nonVegCount', '')), ''), 20),
    left(nullif(trim(coalesce(payload->>'veg_count', payload->>'vegCount', '')), ''), 20),
    left(nullif(trim(coalesce(payload->>'notes', '')), ''), 4000),
    case when jsonb_typeof(coalesce(payload->'veg_menus', payload->'vegMenus')) = 'object'
         then coalesce(payload->'veg_menus', payload->'vegMenus') else '{}'::jsonb end,
    case when jsonb_typeof(payload->'services') = 'object' then payload->'services' else '{}'::jsonb end,
    v_status,
    v_source,
    coalesce(nullif(payload->>'submitted_at', '')::timestamptz, now())
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
    updated_at = now()
  returning * into v_row;

  return json_build_object('id', v_row.id, 'quote_code', v_row.quote_code, 'status', v_row.status);
end;
$$;

revoke all on function public.admin_save_lead(jsonb) from public;
grant execute on function public.admin_save_lead(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Log a WhatsApp message (one-click send) + note
-- ---------------------------------------------------------------------------
create or replace function public.log_lead_whatsapp(p_lead_id uuid, p_template text, p_message text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
  v_email text;
begin
  if not public.has_role_auth(array['platform_owner', 'superadmin', 'opsadmin', 'manager']::public.app_role[]) then
    raise exception 'not_allowed';
  end if;

  select * into v_lead from public.leads where id = p_lead_id;
  if v_lead.id is null then
    raise exception 'lead_not_found';
  end if;
  if not public.is_platform_owner_auth()
     and v_lead.organization_id is distinct from public.current_auth_organization_id() then
    raise exception 'not_allowed';
  end if;

  select u.email into v_email from public.users u where u.id = auth.uid();

  insert into public.lead_activity (lead_id, organization_id, kind, template, message, created_by, created_by_email)
  values (v_lead.id, v_lead.organization_id, 'whatsapp', left(coalesce(p_template, ''), 60), left(coalesce(p_message, ''), 4000), auth.uid(), v_email);

  update public.leads
  set last_contacted_at = now(),
      status = case when status = 'New' then 'Contacted' else status end
  where id = v_lead.id;

  return json_build_object('ok', true);
end;
$$;

revoke all on function public.log_lead_whatsapp(uuid, text, text) from public;
grant execute on function public.log_lead_whatsapp(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Realtime for live dashboard updates
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table public.leads;
    exception when duplicate_object then null;
    end;
    begin
      alter publication supabase_realtime add table public.lead_activity;
    exception when duplicate_object then null;
    end;
  end if;
end $$;
