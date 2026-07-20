(function () {
  function getConfig() {
    const config = window.MAXX_SUPABASE_CONFIG;
    if (!config || !config.url || !config.anonKey) {
      throw new Error(
        "Missing Supabase config. Ensure admin/config.js is loaded with Project URL + anon key."
      );
    }
    if (!window.supabase || !window.supabase.createClient) {
      throw new Error("Supabase JS SDK not loaded.");
    }
    return config;
  }

  function getClient() {
    if (window.__maxxSupabaseClient) return window.__maxxSupabaseClient;
    const config = getConfig();
    window.__maxxSupabaseClient = window.supabase.createClient(config.url, config.anonKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    });
    return window.__maxxSupabaseClient;
  }

  function mapLeadRow(row) {
    if (!row) return null;
    return {
      id: row.id,
      organizationId: row.organization_id,
      quoteCode: row.quote_code,
      name: row.name || "",
      phone: row.phone || "",
      personName: row.person_name || "",
      eventType: row.event_type || "",
      date: row.event_date || "",
      location: row.location || "",
      venueType: row.venue_type || "",
      venueNote: row.venue_note || "",
      budget: row.budget || "",
      servicesCount: row.services_count || 0,
      nonVegCount: row.non_veg_count || "",
      vegCount: row.veg_count || "",
      notes: row.notes || "",
      vegMenus: row.veg_menus || {},
      services: row.services || {},
      status: row.status || "New",
      source: row.source || "form",
      submittedAt: row.submitted_at || "",
      submittedAtRaw: row.submitted_at || null,
    };
  }

  async function createPublicLead(bookerData) {
    const client = getClient();
    const payload = {
      quote_code: bookerData.quoteCode,
      name: bookerData.name,
      phone: bookerData.phone,
      person_name: bookerData.personName || "",
      event_type: bookerData.eventType || "",
      event_date: bookerData.date || null,
      location: bookerData.location || "",
      venue_type: bookerData.venueType || "",
      venue_note: bookerData.venueNote || "",
      budget: bookerData.budget || "",
      services_count: bookerData.servicesCount || 0,
      non_veg_count: bookerData.nonVegCount || "",
      veg_count: bookerData.vegCount || "",
      notes: bookerData.notes || "",
      veg_menus: bookerData.vegMenus || {},
      services: bookerData.services || {},
      status: bookerData.status || "New",
      source: bookerData.source || "form",
      submitted_at: new Date().toISOString(),
    };

    const { data, error } = await client.rpc("create_public_lead", { payload });
    if (error) throw error;
    return data;
  }

  async function listLeads() {
    const client = getClient();
    const { data, error } = await client
      .from("leads")
      .select("*")
      .order("submitted_at", { ascending: false });
    if (error) throw error;
    return (data || []).map(mapLeadRow);
  }

  async function updateLeadStatus(quoteCode, status) {
    const client = getClient();
    const { data, error } = await client
      .from("leads")
      .update({ status })
      .eq("quote_code", quoteCode)
      .select("*")
      .maybeSingle();
    if (error) throw error;
    return mapLeadRow(data);
  }

  window.MaxxLeads = {
    getClient,
    createPublicLead,
    listLeads,
    updateLeadStatus,
    mapLeadRow,
  };
})();
