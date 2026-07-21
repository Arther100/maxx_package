(function () {
  function getClient() {
    if (!window.MaxxAuth || !window.MaxxAuth.client) {
      throw new Error("MaxxAuth is not initialized.");
    }
    return window.MaxxAuth.client;
  }

  function canManage(role) {
    return ["platform_owner", "superadmin", "opsadmin"].includes(role);
  }

  async function resolveOrganizationId(me) {
    if (me && me.organization_id) return me.organization_id;
    const client = getClient();
    const { data, error } = await client
      .from("organizations")
      .select("id")
      .eq("name", "MAXX Events")
      .limit(1)
      .maybeSingle();
    if (error) throw error;
    if (!data || !data.id) throw new Error("No organization available.");
    return data.id;
  }

  async function listOperations(activeOnly) {
    const client = getClient();
    let q = client
      .from("operations")
      .select("id, organization_id, name, code, description, sort_order, is_active, created_at, updated_at")
      .order("sort_order", { ascending: true })
      .order("name", { ascending: true });
    if (activeOnly) q = q.eq("is_active", true);
    const { data, error } = await q;
    if (error) throw error;
    return data || [];
  }

  async function createOperation(input, me) {
    const client = getClient();
    const organizationId = await resolveOrganizationId(me);
    const { data, error } = await client
      .from("operations")
      .insert({
        organization_id: organizationId,
        name: (input.name || "").trim(),
        code: (input.code || "").trim() || null,
        description: (input.description || "").trim() || null,
        sort_order: Number.isFinite(Number(input.sortOrder)) ? Number(input.sortOrder) : 0,
        is_active: input.isActive !== false,
      })
      .select("*")
      .single();
    if (error) throw error;
    return data;
  }

  async function updateOperation(id, input) {
    const client = getClient();
    const { data, error } = await client
      .from("operations")
      .update({
        name: (input.name || "").trim(),
        code: (input.code || "").trim() || null,
        description: (input.description || "").trim() || null,
        sort_order: Number.isFinite(Number(input.sortOrder)) ? Number(input.sortOrder) : 0,
        is_active: !!input.isActive,
        updated_at: new Date().toISOString(),
      })
      .eq("id", id)
      .select("*")
      .single();
    if (error) throw error;
    return data;
  }

  async function deleteOperation(id) {
    const client = getClient();
    const { error } = await client.from("operations").delete().eq("id", id);
    if (error) throw error;
    return true;
  }

  window.MaxxOperations = {
    canManage,
    listOperations,
    createOperation,
    updateOperation,
    deleteOperation,
  };
})();
