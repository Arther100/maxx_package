(function () {
  const EVENT_SELECT =
    "id, organization_id, title, event_date, status, location, venue_name, venue_address, maps_url, event_manager_name, event_manager_phone, upload_opens_at, upload_closes_at, allowed_features, notes, created_by, created_at, updated_at";

  const ALLOWED_FEATURE_OPTIONS = [
    { key: "photo_upload", label: "Photo upload" },
    { key: "video_upload", label: "Video upload" },
    { key: "document_upload", label: "Document upload" },
    { key: "guest_list", label: "Guest list" },
    { key: "vendor_access", label: "Vendor access" },
    { key: "client_portal", label: "Client portal" },
    { key: "checklist", label: "Event checklist" },
    { key: "payments", label: "Payments tracking" },
  ];

  function getClient() {
    if (!window.MaxxAuth || !window.MaxxAuth.client) {
      throw new Error("MaxxAuth is not initialized.");
    }
    return window.MaxxAuth.client;
  }

  async function resolveOrganizationId(me) {
    if (me && me.organization_id) return me.organization_id;

    const client = getClient();
    const { data, error } = await client
      .from("organizations")
      .select("id, name")
      .eq("name", "MAXX Events")
      .limit(1)
      .maybeSingle();
    if (error) throw error;
    if (!data || !data.id) {
      throw new Error("No organization available for event create.");
    }
    return data.id;
  }

  function buildDirectionsUrl(event) {
    if (event && event.maps_url && /google\.[^/]+\/maps/i.test(event.maps_url)) {
      // If a Google Maps link is already a directions link, use it.
      if (/\/dir\//i.test(event.maps_url) || /[?&]api=1.*destination=/i.test(event.maps_url)) {
        return event.maps_url;
      }
    }

    const destination =
      (event && (event.venue_address || event.venue_name || event.location || "")).trim();

    if (destination) {
      return (
        "https://www.google.com/maps/dir/?api=1&destination=" +
        encodeURIComponent(destination)
      );
    }

    if (event && event.maps_url) return event.maps_url;
    return null;
  }

  function buildMapEmbedUrl(event) {
    const q = (
      (event && (event.venue_address || event.venue_name || event.location || "")) ||
      ""
    ).trim();
    if (!q) return null;
    return "https://www.google.com/maps?q=" + encodeURIComponent(q) + "&output=embed";
  }

  function toIsoOrNull(localDateTimeValue) {
    if (!localDateTimeValue) return null;
    const d = new Date(localDateTimeValue);
    if (Number.isNaN(d.getTime())) return null;
    return d.toISOString();
  }

  async function listEvents() {
    const client = getClient();
    const { data, error } = await client
      .from("events")
      .select(EVENT_SELECT)
      .order("created_at", { ascending: false });
    if (error) throw error;
    return data || [];
  }

  async function createEvent(input, me) {
    if (!input || !input.title || !String(input.title).trim()) {
      throw new Error("Event title is required.");
    }

    const client = getClient();
    const organizationId = await resolveOrganizationId(me);
    const session = await MaxxAuth.getSession();
    const createdBy = session && session.user ? session.user.id : null;

    const payload = {
      organization_id: organizationId,
      title: String(input.title).trim(),
      event_date: input.eventDate || null,
      status: input.status || "draft",
      location: (input.location || "").trim() || null,
      venue_name: (input.venueName || "").trim() || null,
      venue_address: (input.venueAddress || "").trim() || null,
      maps_url: (input.mapsUrl || "").trim() || null,
      event_manager_name: (input.eventManagerName || "").trim() || null,
      event_manager_phone: (input.eventManagerPhone || "").trim() || null,
      upload_opens_at: toIsoOrNull(input.uploadOpensAt),
      upload_closes_at: toIsoOrNull(input.uploadClosesAt),
      allowed_features: Array.isArray(input.allowedFeatures) ? input.allowedFeatures : [],
      notes: (input.notes || "").trim() || null,
      created_by: createdBy,
    };

    const { data, error } = await client
      .from("events")
      .insert(payload)
      .select(EVENT_SELECT)
      .single();
    if (error) throw error;
    return data;
  }

  window.MaxxEvents = {
    ALLOWED_FEATURE_OPTIONS,
    listEvents,
    createEvent,
    buildDirectionsUrl,
    buildMapEmbedUrl,
  };
})();
