(function () {
  const EVENT_SELECT =
    "id, organization_id, title, event_date, status, location, venue_name, venue_address, maps_url, upload_opens_at, upload_closes_at, allowed_features, notes, created_by, created_at, updated_at";

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

  function toDateTimeLocalValue(isoValue) {
    if (!isoValue) return "";
    const d = new Date(isoValue);
    if (Number.isNaN(d.getTime())) return "";
    const pad = function (n) { return String(n).padStart(2, "0"); };
    return (
      d.getFullYear() +
      "-" + pad(d.getMonth() + 1) +
      "-" + pad(d.getDate()) +
      "T" + pad(d.getHours()) +
      ":" + pad(d.getMinutes())
    );
  }

  function buildPayload(input, options) {
    options = options || {};
    if (!input || !input.title || !String(input.title).trim()) {
      throw new Error("Event title is required.");
    }

    const payload = {
      title: String(input.title).trim(),
      event_date: input.eventDate || null,
      status: input.status || "draft",
      location: (input.location || "").trim() || null,
      venue_name: (input.venueName || "").trim() || null,
      venue_address: (input.venueAddress || "").trim() || null,
      maps_url: (input.mapsUrl || "").trim() || null,
      upload_opens_at: toIsoOrNull(input.uploadOpensAt),
      upload_closes_at: toIsoOrNull(input.uploadClosesAt),
      allowed_features: Array.isArray(input.allowedFeatures) ? input.allowedFeatures : [],
      notes: (input.notes || "").trim() || null,
    };

    if (options.includeOrganizationId) {
      payload.organization_id = options.organizationId;
    }
    if (options.includeCreatedBy) {
      payload.created_by = options.createdBy;
    }

    return payload;
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
    const client = getClient();
    const organizationId = await resolveOrganizationId(me);
    const session = await MaxxAuth.getSession();
    const createdBy = session && session.user ? session.user.id : null;

    const payload = buildPayload(input, {
      includeOrganizationId: true,
      organizationId: organizationId,
      includeCreatedBy: true,
      createdBy: createdBy,
    });

    const { data, error } = await client
      .from("events")
      .insert(payload)
      .select(EVENT_SELECT)
      .single();
    if (error) throw error;
    return data;
  }

  async function updateEvent(eventId, input) {
    if (!eventId) throw new Error("Event id is required for update.");
    const client = getClient();
    const payload = buildPayload(input);

    const { data, error } = await client
      .from("events")
      .update(payload)
      .eq("id", eventId)
      .select(EVENT_SELECT)
      .single();
    if (error) throw error;
    return data;
  }

  async function deleteEvent(eventId) {
    if (!eventId) throw new Error("Event id is required for delete.");
    const client = getClient();
    const { error } = await client.from("events").delete().eq("id", eventId);
    if (error) throw error;
    return true;
  }

  function subscribeEvents(onChange) {
    const client = getClient();
    const channel = client
      .channel("maxx-events-changes")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "events" },
        function (payload) {
          if (typeof onChange === "function") onChange(payload);
        }
      )
      .subscribe();
    return channel;
  }

  function unsubscribe(channel) {
    if (!channel) return;
    const client = getClient();
    client.removeChannel(channel);
  }

  window.MaxxEvents = {
    ALLOWED_FEATURE_OPTIONS,
    listEvents,
    createEvent,
    updateEvent,
    deleteEvent,
    subscribeEvents,
    unsubscribe,
    buildDirectionsUrl,
    buildMapEmbedUrl,
    toDateTimeLocalValue,
  };
})();
