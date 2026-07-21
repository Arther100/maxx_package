(function () {
  const config = window.MAXX_SUPABASE_CONFIG;

  if (!config || !config.url || !config.anonKey) {
    throw new Error(
      "Missing Supabase config. Copy admin/config.example.js to admin/config.js and set your project URL + anon key."
    );
  }

  if (!window.supabase || !window.supabase.createClient) {
    throw new Error("Supabase JS SDK not loaded.");
  }

  const client = window.supabase.createClient(config.url, config.anonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  });

  async function getSession() {
    const { data, error } = await client.auth.getSession();
    if (error) throw error;
    return data.session;
  }

  async function signIn(email, password) {
    const { data, error } = await client.auth.signInWithPassword({
      email,
      password,
    });
    if (error) throw error;
    return data;
  }

  async function signOut() {
    const { error } = await client.auth.signOut();
    if (error) throw error;
  }

  async function getMe() {
    const { data, error } = await client.rpc("get_me");
    if (error) throw error;
    if (!data) {
      throw new Error("No profile found for this auth user in public.users.");
    }
    return data;
  }

  async function requireAuth(loginPath) {
    const session = await getSession();
    if (!session) {
      window.location.href = loginPath || "login.html";
      return null;
    }
    return session;
  }

  function canAccessModule(role, moduleKey) {
    // Managers/clients: Event Feed only (upload/view). Full admin menus = superadmin/opsadmin/platform_owner.
    const map = {
      dashboard: ["platform_owner", "superadmin", "opsadmin"],
      events: ["platform_owner", "superadmin", "opsadmin"],
      leads: ["platform_owner", "superadmin", "opsadmin"],
      users: ["platform_owner", "superadmin", "opsadmin"],
      event_assign: ["platform_owner", "superadmin", "opsadmin"],
      operations: ["platform_owner", "superadmin", "opsadmin"],
      event_feed: ["platform_owner", "superadmin", "opsadmin", "manager", "client"],
      booking_form: ["platform_owner", "superadmin", "opsadmin"],
      manual_entry: ["platform_owner", "superadmin", "opsadmin"],
    };
    return (map[moduleKey] || []).includes(role);
  }

  function isFullAdmin(role) {
    return ["platform_owner", "superadmin", "opsadmin"].includes(role);
  }

  /** Relative to admin/ pages. */
  function homeForRole(role) {
    if (role === "manager" || role === "client") return "event-feed.html";
    return "index.html";
  }

  /**
   * Same header on every screen: filter by role + highlight current page.
   * Call after getMe() on admin pages and bookers-details.
   */
  function applyAdminNav(role) {
    const path = String(window.location.pathname || "").replace(/\\/g, "/").toLowerCase();
    const file = path.split("/").pop() || "";

    document.querySelectorAll("[data-module]").forEach(function (el) {
      const key = el.getAttribute("data-module");
      if (!canAccessModule(role, key)) {
        el.style.display = "none";
        el.classList.remove("nav-active");
        return;
      }

      el.style.display = "";
      el.classList.remove("nav-active");

      var inTopNav = !!(el.closest && el.closest("#topNav"));
      if (!inTopNav) return;

      var active = false;
      if (key === "dashboard" && path.indexOf("/admin") !== -1 && (file === "index.html" || file === "")) {
        active = true;
      }
      if (key === "events" && file === "events.html") active = true;
      if (key === "event_assign" && file === "event-assign.html") active = true;
      if (key === "operations" && file === "operations.html") active = true;
      if (key === "event_feed" && file === "event-feed.html") active = true;
      if (key === "users" && file === "users.html") active = true;
      if (key === "leads" && path.indexOf("bookers-details") !== -1) active = true;
      if (key === "booking_form" && path.indexOf("booking_form") !== -1) active = true;
      if (key === "manual_entry" && path.indexOf("manual-entry") !== -1) active = true;

      if (active) el.classList.add("nav-active");
    });
  }

  window.MaxxAuth = {
    client,
    getSession,
    signIn,
    signOut,
    getMe,
    requireAuth,
    canAccessModule,
    isFullAdmin,
    homeForRole,
    applyAdminNav,
  };
})();
