-- 014: Capture leads BEFORE the final "Confirm" tap (drop-off protection).
-- Run AFTER 013. Safe to re-run.
--
-- * New lead status: 'Incomplete' (customer entered name + phone but did not confirm).
-- * save_public_lead_draft(): the booking form saves/updates a draft after each step.
--   A secret token (kept only in the customer's browser, stored here only as a hash)
--   is required to update a draft, so nobody else can edit it.
-- * create_public_lead(payload, p_token): the final Confirm turns the draft into 'New'.
--   Without a token it behaves exactly like before (creates a new lead).

-- ---------------------------------------------------------------------------
-- 1. Columns + status list
-- ---------------------------------------------------------------------------
alter table public.leads add column if not exists last_step integer;
alter table public.leads add column if not exists draft_token_hash text;

alter table public.leads drop constraint if exists leads_status_check;
alter table public.leads
  add constraint leads_status_check
  check (status in ('Incomplete', 'New', 'Contacted', 'Quoted', 'Confirmed', 'Cancelled'));

create index if not exists idx_leads_draft_token_hash on public.leads(draft_token_hash)
  where draft_token_hash is not null;

-- ---------------------------------------------------------------------------
-- 2. Helper: read + sanitise the form payload (shared by draft/final)
-- ---------------------------------------------------------------------------
create or replace function public.lead_fields_from_payload(payload jsonb)
returns public.leads
language plpgsql
immutable
set search_path = public
as $$
declare
  r public.leads;
begin
  r.name := left(trim(coalesce(payload->>'name', '')), 100);
  r.phone := left(trim(coalesce(payload->>'phone', '')), 30);
  r.person_name := left(nullif(trim(coalesce(payload->>'person_name', payload->>'personName', '')), ''), 100);
  r.event_type := left(nullif(trim(coalesce(payload->>'event_type', payload->>'eventType', '')), ''), 100);
  begin
    r.event_date := nullif(trim(coalesce(payload->>'event_date', payload->>'date', '')), '')::date;
  exception when others then
    r.event_date := null;
  end;
  r.location := left(nullif(trim(coalesce(payload->>'location', '')), ''), 200);
  r.venue_type := left(nullif(trim(coalesce(payload->>'venue_type', payload->>'venueType', '')), ''), 100);
  r.venue_note := left(nullif(trim(coalesce(payload->>'venue_note', payload->>'venueNote', payload->>'venueName', '')), ''), 200);
  r.budget := left(nullif(trim(coalesce(payload->>'budget', '')), ''), 60);
  r.services_count := public.safe_int(coalesce(payload->>'services_count', payload->>'servicesCount'), 0);
  r.non_veg_count := left(nullif(trim(coalesce(payload->>'non_veg_count', payload->>'nonVegCount', '')), ''), 20);
  r.veg_count := left(nullif(trim(coalesce(payload->>'veg_count', payload->>'vegCount', '')), ''), 20);
  r.notes := left(nullif(trim(coalesce(payload->>'notes', '')), ''), 4000);
  r.veg_menus := case when jsonb_typeof(coalesce(payload->'veg_menus', payload->'vegMenus')) = 'object'
                      then coalesce(payload->'veg_menus', payload->'vegMenus') else '{}'::jsonb end;
  r.services := case when jsonb_typeof(payload->'services') = 'object' then payload->'services' else '{}'::jsonb end;
  r.last_step := least(greatest(public.safe_int(payload->>'last_step', 0), 0), 6);
  return r;
end;
$$;

revoke all on function public.lead_fields_from_payload(jsonb) from public;

-- ---------------------------------------------------------------------------
-- 3. Save / update a DRAFT (anon)
-- ---------------------------------------------------------------------------
create or replace function public.save_public_lead_draft(payload jsonb, p_token text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  f public.leads;
  v_e164 text;
  v_hash text;
  v_token text;
  v_row public.leads;
begin
  select o.id into v_org_id
  from public.organizations o
  where o.name = 'MAXX Events' and coalesce(o.status, 'active') = 'active'
  limit 1;
  if v_org_id is null then
    raise exception 'MAXX Events organization not found';
  end if;

  f := public.lead_fields_from_payload(payload);
  if length(f.name) < 2 then raise exception 'invalid_name'; end if;
  v_e164 := public.normalize_phone_in(f.phone);
  if v_e164 is null then raise exception 'invalid_phone'; end if;

  -- Update an existing draft (token must match; only while still Incomplete).
  if p_token is not null and length(p_token) >= 32 then
    v_hash := encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
    select * into v_row from public.leads
    where organization_id = v_org_id and draft_token_hash = v_hash;

    if v_row.id is not null then
      if v_row.status = 'Incomplete' then
        update public.leads set
          name = f.name, phone = f.phone, person_name = f.person_name, event_type = f.event_type,
          event_date = f.event_date, location = f.location, venue_type = f.venue_type,
          venue_note = f.venue_note, budget = f.budget, services_count = f.services_count,
          non_veg_count = f.non_veg_count, veg_count = f.veg_count, notes = f.notes,
          veg_menus = f.veg_menus, services = f.services,
          last_step = greatest(coalesce(last_step, 0), f.last_step)
        where id = v_row.id
        returning * into v_row;
      end if;
      -- already confirmed -> nothing to change, just echo
      return json_build_object('quote_code', v_row.quote_code, 'status', v_row.status, 'token', p_token);
    end if;
    -- unknown token -> fall through and start a fresh draft
  end if;

  -- New draft: same spam guard as final submissions.
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

  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_hash := encode(sha256(convert_to(v_token, 'UTF8')), 'hex');

  insert into public.leads (
    organization_id, quote_code, name, phone, person_name, event_type, event_date, location,
    venue_type, venue_note, budget, services_count, non_veg_count, veg_count, notes,
    veg_menus, services, status, source, submitted_at, last_step, draft_token_hash
  ) values (
    v_org_id, public.gen_lead_quote_code(v_org_id), f.name, f.phone, f.person_name, f.event_type,
    f.event_date, f.location, f.venue_type, f.venue_note, f.budget, f.services_count,
    f.non_veg_count, f.veg_count, f.notes, f.veg_menus, f.services,
    'Incomplete', 'form', now(), f.last_step, v_hash
  ) returning * into v_row;

  return json_build_object('quote_code', v_row.quote_code, 'status', v_row.status, 'token', v_token);
end;
$$;

revoke all on function public.save_public_lead_draft(jsonb, text) from public;
grant execute on function public.save_public_lead_draft(jsonb, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Final confirm (anon): turns a draft into 'New', or creates a new lead
-- ---------------------------------------------------------------------------
drop function if exists public.create_public_lead(jsonb);

create or replace function public.create_public_lead(payload jsonb, p_token text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  f public.leads;
  v_e164 text;
  v_hash text;
  v_row public.leads;
begin
  select o.id into v_org_id
  from public.organizations o
  where o.name = 'MAXX Events' and coalesce(o.status, 'active') = 'active'
  limit 1;
  if v_org_id is null then
    raise exception 'MAXX Events organization not found';
  end if;

  f := public.lead_fields_from_payload(payload);
  if length(f.name) < 2 then raise exception 'invalid_name'; end if;
  v_e164 := public.normalize_phone_in(f.phone);
  if v_e164 is null then raise exception 'invalid_phone'; end if;

  -- Finish the customer's own draft (token must match).
  if p_token is not null and length(p_token) >= 32 then
    v_hash := encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
    select * into v_row from public.leads
    where organization_id = v_org_id and draft_token_hash = v_hash and status = 'Incomplete'
    for update;

    if v_row.id is not null then
      update public.leads set
        name = f.name, phone = f.phone, person_name = f.person_name, event_type = f.event_type,
        event_date = f.event_date, location = f.location, venue_type = f.venue_type,
        venue_note = f.venue_note, budget = f.budget, services_count = f.services_count,
        non_veg_count = f.non_veg_count, veg_count = f.veg_count, notes = f.notes,
        veg_menus = f.veg_menus, services = f.services,
        status = 'New', last_step = 6, submitted_at = now(), draft_token_hash = null
      where id = v_row.id
      returning * into v_row;
      return json_build_object('id', v_row.id, 'quote_code', v_row.quote_code, 'status', v_row.status);
    end if;
  end if;

  -- No usable draft: create a fresh confirmed lead (same rules as migration 013).
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

  insert into public.leads (
    organization_id, quote_code, name, phone, person_name, event_type, event_date, location,
    venue_type, venue_note, budget, services_count, non_veg_count, veg_count, notes,
    veg_menus, services, status, source, submitted_at, last_step
  ) values (
    v_org_id, public.gen_lead_quote_code(v_org_id), f.name, f.phone, f.person_name, f.event_type,
    f.event_date, f.location, f.venue_type, f.venue_note, f.budget, f.services_count,
    f.non_veg_count, f.veg_count, f.notes, f.veg_menus, f.services,
    'New', 'form', now(), 6
  ) returning * into v_row;

  return json_build_object('id', v_row.id, 'quote_code', v_row.quote_code, 'status', v_row.status);
end;
$$;

revoke all on function public.create_public_lead(jsonb, text) from public;
grant execute on function public.create_public_lead(jsonb, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Admin save: allow the Incomplete status too
-- ---------------------------------------------------------------------------
-- (admin_save_lead from 013 whitelists statuses; re-create it with 'Incomplete' included.)
do $$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'admin_save_lead';

  if v_def is not null and position('''Incomplete''' in v_def) = 0 then
    v_def := replace(v_def,
      'if v_status not in (''New'', ''Contacted'', ''Quoted'', ''Confirmed'', ''Cancelled'') then',
      'if v_status not in (''Incomplete'', ''New'', ''Contacted'', ''Quoted'', ''Confirmed'', ''Cancelled'') then');
    execute v_def;
  end if;
end $$;
