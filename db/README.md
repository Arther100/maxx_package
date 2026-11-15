# MAXX SaaS-Ready Database Baseline

This project now includes an additive migration at:

- `db/migrations/001_saas_ready_foundation.sql`
- `db/migrations/002_supabase_auth_rls_alignment.sql`
- `db/migrations/003_align_auth_user_ids.sql`
- `db/migrations/004_get_me_rpc.sql`
- `db/migrations/005_leads_booking_pipeline.sql`
- `db/migrations/006_events_details_and_settings.sql`
- `db/migrations/007_user_management.sql`
- `db/migrations/008_event_members_uploads_and_client_scope.sql`
- `db/migrations/009_manager_assigned_events_only.sql`
- `db/migrations/010_fix_manager_upload_rls.sql`
- `db/migrations/011_operations_and_event_member_ops.sql`
- `db/migrations/012_upload_operation_scope.sql`
- `db/migrations/013_leads_hardening_activity.sql`
- `db/migrations/014_incomplete_leads_drafts.sql`

It sets up:

- `organizations` table
- `organization_id` scoping on business tables (`users`, `events`)
- `platform_owner` + org-scoped roles
- row-level security (RLS) with `organization_id` enforcement for non-platform-owner policies
- required seed records
- Supabase Auth-aware RLS (`auth.uid()` driven helper functions)
- role + organization enforced policies for `organizations`, `users`, `events`

## Seed records created

- Organization: `MAXX Events`
- User: `platform.owner@maxxevents.local` with role `platform_owner` and `organization_id = null`
- User: `superadmin@maxxevents.local` with role `superadmin` scoped to MAXX org

## Migration run order

1. Run `001_saas_ready_foundation.sql`
2. In Supabase Auth, create users for:
   - `platform.owner@maxxevents.local`
   - `superadmin@maxxevents.local`
3. Run `002_supabase_auth_rls_alignment.sql`
4. Run `003_align_auth_user_ids.sql` (fixes `public.users.id` = `auth.users.id`)
5. Run `004_get_me_rpc.sql` (profile RPC used by admin frontend)
6. Run `005_leads_booking_pipeline.sql` (booking form → DB + leads dashboard)
7. Run `006_events_details_and_settings.sql` (venue/maps/manager/upload/allowed features)
8. Run `007_user_management.sql` (link Auth users + assign roles from admin UI)
9. Run `008_event_members_uploads_and_client_scope.sql` (event members + uploads + client event-only feed scope)
10. Run `009_manager_assigned_events_only.sql` (managers see only assigned events, same as clients)
11. Run `010_fix_manager_upload_rls.sql` (assigned managers can post; upload window defaults open)
12. Run `011_operations_and_event_member_ops.sql` (operations CRUD + operation on event assignment)
13. Run `012_upload_operation_scope.sql` (managers see only their operation’s uploads per event)

Migration `002` rebuilds policies to use authenticated user context.
Migration `003` is required if verification shows `id_aligned = false`.
Run `003` in Supabase SQL Editor (it uses a `SECURITY DEFINER` function to bypass RLS safely).
Migration `004` adds `get_me()` for frontend profile bootstrap.
Migration `005` adds `leads` table, org-scoped RLS, and `create_public_lead()` for the public booking form.
Migration `006` extends `events` with location, venue, maps link, manager settings, upload window, and allowed features.
Migration `007` adds `admin_link_org_user` / `admin_update_org_user` RPCs for User Management.
Migration `008` adds `event_members`, `event_uploads`, client event-scoped access, and upload feed policies.
Migration `009` restricts managers to assigned events only (admins still see all org events).
Migration `010` fixes manager upload RLS / upload-window default so assigned managers can post.
Migration `011` adds `operations` (Decor/Food/Photography/…) and `event_members.operation_id`.
Migration `012` scopes `event_uploads` by operation so managers only see their own op feed.

## Verification queries

```sql
select id, name, status, created_at
from public.organizations;

select email, role, organization_id
from public.users
where email in ('platform.owner@maxxevents.local', 'superadmin@maxxevents.local');

select schemaname, tablename, policyname, cmd
from pg_policies
where schemaname = 'public'
  and tablename in ('organizations', 'users', 'events')
order by tablename, policyname;

select
  pu.email,
  pu.id as public_user_id,
  au.id as auth_user_id,
  (pu.id = au.id) as id_aligned,
  pu.role,
  pu.organization_id
from public.users pu
left join auth.users au on lower(au.email) = lower(pu.email)
where pu.email in ('platform.owner@maxxevents.local', 'superadmin@maxxevents.local');
```

Expected: both rows show `id_aligned = true`.

## Runtime requirement

With migration `002`, RLS uses Supabase auth context automatically via `auth.uid()`.
No manual `set_config(...)` is needed in normal app requests.


## Migration 013 (leads hardening + activity log)

Run `013_leads_hardening_activity.sql` in the Supabase SQL editor **before** deploying the new
`bookers-details.html`, `manual-entry.html`, `booking_form/` and `js/maxx-leads.js`.

What it changes:

- `create_public_lead` (public booking form): server creates the unique quote code, status/source are forced
  to `New`/`form`, phone is validated + normalised (India +91), max 5 leads per phone per hour, length caps.
  It can no longer overwrite an existing lead.
- `admin_save_lead` (new): used by Manual Entry / Import. Needs `superadmin`, `opsadmin` or `platform_owner`.
- `lead_activity` (new): status history, WhatsApp messages opened, notes. Status changes are logged by a trigger.
- `log_lead_whatsapp` (new): logs a WhatsApp message and moves `New` -> `Contacted`.
- `leads.phone_e164` + `leads.last_contacted_at`, new indexes, realtime enabled for `leads` and `lead_activity`.

## Google Sheet script (`maxx-quotes-sheet.gs`)

The web app used to return every lead to anyone and let anyone change/delete rows. Now:

1. Apps Script -> Project Settings -> Script properties -> add `ADMIN_TOKEN` = a long random string.
2. Paste the updated `maxx-quotes-sheet.gs`, then Deploy -> Manage deployments -> New version.
3. The leads dashboard "More -> Import from Google Sheet" asks for that token once (not stored).
Without `ADMIN_TOKEN` the read/admin actions stay disabled. The booking form can still add NEW rows.


## Migration 014 (drop-off protection: Incomplete leads)

Run `014_incomplete_leads_drafts.sql` AFTER 013 and BEFORE using the new booking form.

- New lead status `Incomplete` (customer gave name + phone but did not press Confirm).
- `save_public_lead_draft(payload, p_token)`: the booking form saves/updates a draft after every step from
  "Details" onward. A secret token (kept only in the customer's browser tab, stored in the DB only as a SHA-256 hash)
  is needed to update a draft, so nobody else can edit it.
- `create_public_lead(payload, p_token)`: the final **Confirm My Request** turns the draft into `New`
  (the old one-argument version is dropped; old callers still work because `p_token` is optional).
- `leads.last_step` records how far the customer got. The Leads page shows "Stopped at: Venue (step 3 of 6)",
  an Incomplete filter/stat and a "Complete your booking" WhatsApp template.
