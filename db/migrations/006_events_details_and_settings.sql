-- Extend events with venue/location/maps + manager settings.
-- Additive only; existing event rows remain valid.

alter table public.events
  add column if not exists location text,
  add column if not exists venue_name text,
  add column if not exists venue_address text,
  add column if not exists maps_url text,
  add column if not exists event_manager_name text,
  add column if not exists event_manager_phone text,
  add column if not exists upload_opens_at timestamptz,
  add column if not exists upload_closes_at timestamptz,
  add column if not exists allowed_features jsonb not null default '[]'::jsonb,
  add column if not exists notes text;

comment on column public.events.location is 'City / area for the event';
comment on column public.events.venue_name is 'Hall / mandapam / hotel name';
comment on column public.events.venue_address is 'Full address used for maps destination';
comment on column public.events.maps_url is 'Optional Google Maps place/share link';
comment on column public.events.event_manager_name is 'On-site event manager display name';
comment on column public.events.event_manager_phone is 'Event manager contact phone';
comment on column public.events.upload_opens_at is 'When uploads/content submission opens';
comment on column public.events.upload_closes_at is 'Upload deadline / close time';
comment on column public.events.allowed_features is 'JSON array of allowed feature keys for this event';
comment on column public.events.notes is 'Internal event notes';
