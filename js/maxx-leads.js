/* MAXX leads data layer (Supabase) + phone / WhatsApp helpers.
 * Needs: Supabase JS SDK, admin/config.js. DB migrations 005 + 013.
 */
(function () {
  var BUSINESS_PHONE = "918778667396"; // MAXX Events WhatsApp (digits only, with country code)
  var BUSINESS_PHONE_DISPLAY = "+91 87786 67396";
  var PAGE_SIZE = 1000;

  function getConfig() {
    var config = window.MAXX_SUPABASE_CONFIG;
    if (!config || !config.url || !config.anonKey) {
      throw new Error("Missing Supabase config. Ensure admin/config.js is loaded with Project URL + anon key.");
    }
    if (!window.supabase || !window.supabase.createClient) {
      throw new Error("Supabase JS SDK not loaded.");
    }
    return config;
  }

  function getClient() {
    // Reuse the admin auth client when present so both share one login session.
    if (window.MaxxAuth && window.MaxxAuth.client) return window.MaxxAuth.client;
    if (window.__maxxSupabaseClient) return window.__maxxSupabaseClient;
    var config = getConfig();
    window.__maxxSupabaseClient = window.supabase.createClient(config.url, config.anonKey, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
    });
    return window.__maxxSupabaseClient;
  }

  /* ---------- phone helpers (mirror of SQL public.normalize_phone_in) ---------- */

  // Returns digits with country code (e.g. 919876543210) or "" when invalid.
  function normalizePhone(phone) {
    var d = String(phone || "").replace(/\D/g, "").replace(/^00/, "");
    if (!d) return "";
    if (d.length === 10 && /^[6-9]/.test(d)) return "91" + d;
    if (d.length === 11 && /^0[6-9]/.test(d)) return "91" + d.slice(1);
    if (d.length >= 11 && d.length <= 15 && d.charAt(0) !== "0") return d;
    return "";
  }

  function isValidPhone(phone) {
    return normalizePhone(phone) !== "";
  }

  // "919876543210" -> "+91 98765 43210"
  function formatPhone(phone) {
    var n = normalizePhone(phone);
    if (!n) return String(phone || "");
    if (n.indexOf("91") === 0 && n.length === 12) return "+91 " + n.slice(2, 7) + " " + n.slice(7);
    return "+" + n;
  }

  function whatsappUrl(phone, message) {
    var n = normalizePhone(phone);
    if (!n) return "";
    return "https://wa.me/" + n + (message ? "?text=" + encodeURIComponent(message) : "");
  }

  /* ---------- row mapping ---------- */

  function mapLeadRow(row) {
    if (!row) return null;
    return {
      id: row.id,
      organizationId: row.organization_id,
      quoteCode: row.quote_code,
      name: row.name || "",
      phone: row.phone || "",
      phoneE164: row.phone_e164 || normalizePhone(row.phone),
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
      submittedAt: row.submitted_at || row.created_at || "",
      lastContactedAt: row.last_contacted_at || "",
    };
  }

  function toPayload(b) {
    return {
      quote_code: b.quoteCode || undefined,
      name: b.name,
      phone: b.phone,
      person_name: b.personName || "",
      event_type: b.eventType || "",
      event_date: b.date || null,
      location: b.location || "",
      venue_type: b.venueType || "",
      venue_note: b.venueNote || "",
      budget: b.budget || "",
      services_count: b.servicesCount || 0,
      non_veg_count: b.nonVegCount || "",
      veg_count: b.vegCount || "",
      notes: b.notes || "",
      veg_menus: b.vegMenus || {},
      services: b.services || {},
      status: b.status || "New",
      source: b.source || "form",
      submitted_at: b.submittedAtIso || undefined,
    };
  }

  /* ---------- writes ---------- */

  // Public booking form. The SERVER generates the quote code and returns it.
  async function createPublicLead(bookerData) {
    var res = await getClient().rpc("create_public_lead", { payload: toPayload(bookerData) });
    if (res.error) throw res.error;
    return res.data; // { id, quote_code, status }
  }

  // Admin tools (manual entry / import). Needs superadmin / opsadmin / platform_owner.
  async function createAdminLead(bookerData) {
    var res = await getClient().rpc("admin_save_lead", { payload: toPayload(bookerData) });
    if (res.error) throw res.error;
    return res.data;
  }

  async function updateLeadStatus(leadId, status) {
    var res = await getClient()
      .from("leads")
      .update({ status: status })
      .eq("id", leadId)
      .select("*")
      .maybeSingle();
    if (res.error) throw res.error;
    return mapLeadRow(res.data);
  }

  async function logWhatsApp(leadId, template, message) {
    var res = await getClient().rpc("log_lead_whatsapp", {
      p_lead_id: leadId,
      p_template: template || "custom",
      p_message: message || "",
    });
    if (res.error) throw res.error;
    return res.data;
  }

  async function addNote(lead, note) {
    var text = String(note || "").trim();
    if (!text) throw new Error("Note is empty.");
    var res = await getClient()
      .from("lead_activity")
      .insert({ lead_id: lead.id, organization_id: lead.organizationId, kind: "note", note: text.slice(0, 2000) })
      .select("*")
      .maybeSingle();
    if (res.error) throw res.error;
    return res.data;
  }

  /* ---------- reads ---------- */

  // Reads every lead (pages of 1000) so long-term growth never truncates silently.
  async function listLeads() {
    var client = getClient();
    var all = [];
    var from = 0;
    for (;;) {
      var res = await client
        .from("leads")
        .select("*")
        .order("submitted_at", { ascending: false })
        .range(from, from + PAGE_SIZE - 1);
      if (res.error) throw res.error;
      var rows = res.data || [];
      all = all.concat(rows);
      if (rows.length < PAGE_SIZE) break;
      from += PAGE_SIZE;
    }
    return all.map(mapLeadRow);
  }

  async function listActivity(leadId) {
    var res = await getClient()
      .from("lead_activity")
      .select("*")
      .eq("lead_id", leadId)
      .order("created_at", { ascending: false });
    if (res.error) throw res.error;
    return res.data || [];
  }

  /* ---------- realtime ---------- */

  function subscribeLeads(onChange) {
    var client = getClient();
    return client
      .channel("maxx-leads-changes")
      .on("postgres_changes", { event: "*", schema: "public", table: "leads" }, function (payload) {
        if (typeof onChange === "function") onChange(payload);
      })
      .subscribe();
  }

  function unsubscribe(channel) {
    if (!channel) return;
    getClient().removeChannel(channel);
  }

  /* ---------- WhatsApp message templates ---------- */

  function fmtDate(d) {
    if (!d) return "your event date";
    var dt = new Date(String(d).length === 10 ? d + "T00:00:00" : d);
    if (isNaN(dt.getTime())) return String(d);
    return dt.toLocaleDateString("en-IN", { day: "numeric", month: "long", year: "numeric" });
  }

  var TEMPLATES = [
    {
      key: "confirmation",
      label: "Enquiry received",
      build: function (l) {
        return [
          "Hi " + l.name + " 🙏",
          "Thank you for choosing *MAXX Events & Planners*!",
          "",
          "We have received your " + (l.eventType || "event") + " enquiry.",
          "🔖 Reference: *" + l.quoteCode + "*",
          "📅 Date: " + fmtDate(l.date),
          l.location ? "📍 Location: " + l.location : null,
          "",
          "Our team will share your personalised package and price shortly.",
          "",
          "— MAXX Events & Planners",
          BUSINESS_PHONE_DISPLAY,
        ].filter(function (x) { return x !== null; }).join("\n");
      },
    },
    {
      key: "quote",
      label: "Quote ready",
      build: function (l) {
        return [
          "Hi " + l.name + " 🙏",
          "Your quote for the " + (l.eventType || "event") + " on " + fmtDate(l.date) + " is ready.",
          "🔖 Reference: *" + l.quoteCode + "*",
          l.budget ? "💰 Budget you selected: " + l.budget : null,
          "",
          "Reply here and we will walk you through the details.",
          "",
          "— MAXX Events & Planners",
        ].filter(function (x) { return x !== null; }).join("\n");
      },
    },
    {
      key: "followup",
      label: "Follow-up",
      build: function (l) {
        return [
          "Hi " + l.name + " 🙏",
          "Following up on your " + (l.eventType || "event") + " enquiry (Ref *" + l.quoteCode + "*).",
          "Do you have any questions or changes? We are happy to help.",
          "",
          "— MAXX Events & Planners",
        ].join("\n");
      },
    },
    {
      key: "confirmed",
      label: "Booking confirmed",
      build: function (l) {
        return [
          "Hi " + l.name + " 🎉",
          "Your *" + (l.eventType || "event") + "* on " + fmtDate(l.date) + " is confirmed with MAXX Events & Planners.",
          "🔖 Reference: *" + l.quoteCode + "*",
          "",
          "We will be in touch with the next steps. Thank you for trusting us!",
          "",
          "— MAXX Events & Planners",
          BUSINESS_PHONE_DISPLAY,
        ].join("\n");
      },
    },
  ];

  function buildMessage(templateKey, lead) {
    for (var i = 0; i < TEMPLATES.length; i++) {
      if (TEMPLATES[i].key === templateKey) return TEMPLATES[i].build(lead);
    }
    return "";
  }

  window.MaxxLeads = {
    BUSINESS_PHONE: BUSINESS_PHONE,
    BUSINESS_PHONE_DISPLAY: BUSINESS_PHONE_DISPLAY,
    TEMPLATES: TEMPLATES,
    getClient: getClient,
    normalizePhone: normalizePhone,
    isValidPhone: isValidPhone,
    formatPhone: formatPhone,
    whatsappUrl: whatsappUrl,
    buildMessage: buildMessage,
    mapLeadRow: mapLeadRow,
    createPublicLead: createPublicLead,
    createAdminLead: createAdminLead,
    listLeads: listLeads,
    listActivity: listActivity,
    updateLeadStatus: updateLeadStatus,
    logWhatsApp: logWhatsApp,
    addNote: addNote,
    subscribeLeads: subscribeLeads,
    unsubscribe: unsubscribe,
  };
})();
