(function () {
  const ROLE_OPTIONS = [
    { value: "superadmin", label: "SuperAdmin" },
    { value: "opsadmin", label: "OpsAdmin" },
    { value: "manager", label: "Manager" },
    { value: "client", label: "Client" },
  ];

  function getClient() {
    if (!window.MaxxAuth || !window.MaxxAuth.client) {
      throw new Error("MaxxAuth is not initialized.");
    }
    return window.MaxxAuth.client;
  }

  function assignableRolesFor(callerRole) {
    if (callerRole === "platform_owner") {
      return [{ value: "platform_owner", label: "Platform Owner" }].concat(ROLE_OPTIONS);
    }
    if (callerRole === "superadmin") {
      return ROLE_OPTIONS.slice();
    }
    if (callerRole === "opsadmin") {
      return ROLE_OPTIONS.filter(function (r) {
        return r.value === "opsadmin" || r.value === "manager" || r.value === "client";
      });
    }
    return [];
  }

  function canManageUsers(role) {
    return ["platform_owner", "superadmin", "opsadmin"].includes(role);
  }

  function canDeleteUsers(role) {
    return ["platform_owner", "superadmin"].includes(role);
  }

  async function listUsers() {
    const client = getClient();
    const { data, error } = await client
      .from("users")
      .select("id, email, full_name, role, organization_id, created_at, updated_at")
      .order("created_at", { ascending: false });
    if (error) throw error;
    return data || [];
  }

  async function linkUser({ email, fullName, role }) {
    const client = getClient();
    const { data, error } = await client.rpc("admin_link_org_user", {
      p_email: email,
      p_full_name: fullName || "",
      p_role: role,
    });
    if (error) throw error;
    return data;
  }

  /**
   * Create Auth login + public.users profile in one step (Edge Function).
   * Requires deployed function: admin-create-user
   */
  async function createUser({ email, password, fullName, role }) {
    const client = getClient();
    const { data, error } = await client.functions.invoke("admin-create-user", {
      body: {
        email: email,
        password: password,
        full_name: fullName || "",
        role: role,
      },
    });

    if (data && data.error) throw new Error(data.error);

    if (error) {
      let detail = error.message || "Failed to create user.";
      try {
        if (error.context && typeof error.context.json === "function") {
          const body = await error.context.json();
          if (body && body.error) detail = body.error;
        }
      } catch (_) {}
      throw new Error(detail);
    }

    return (data && data.user) || data;
  }

  async function updateUser({ userId, fullName, role }) {
    const client = getClient();
    const { data, error } = await client.rpc("admin_update_org_user", {
      p_user_id: userId,
      p_full_name: fullName || "",
      p_role: role,
    });
    if (error) throw error;
    return data;
  }

  async function deleteUser(userId) {
    const client = getClient();
    const { error } = await client.from("users").delete().eq("id", userId);
    if (error) throw error;
    return true;
  }

  window.MaxxUsers = {
    ROLE_OPTIONS,
    assignableRolesFor,
    canManageUsers,
    canDeleteUsers,
    listUsers,
    createUser,
    linkUser,
    updateUser,
    deleteUser,
  };
})();
