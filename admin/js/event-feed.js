(function () {
  function getClient() {
    if (!window.MaxxAuth || !window.MaxxAuth.client) {
      throw new Error("MaxxAuth is not initialized.");
    }
    return window.MaxxAuth.client;
  }

  function canAssign(role) {
    return ["platform_owner", "superadmin", "opsadmin"].includes(role);
  }

  function canUpload(role) {
    return ["platform_owner", "superadmin", "opsadmin", "manager"].includes(role);
  }

  async function listAccessibleEvents() {
    const client = getClient();
    const { data, error } = await client
      .from("events")
      .select("id, title, event_date, organization_id")
      .order("event_date", { ascending: true, nullsFirst: false });
    if (error) throw error;
    return data || [];
  }

  async function listAssignableUsers() {
    const client = getClient();
    const { data, error } = await client
      .from("users")
      .select("id, email, full_name, role")
      .in("role", ["manager", "client"])
      .order("role", { ascending: true })
      .order("created_at", { ascending: false });
    if (error) throw error;
    return data || [];
  }

  async function listEventMembers(eventId) {
    if (!eventId) return [];
    const client = getClient();
    const { data, error } = await client
      .from("event_members")
      .select("id, event_id, user_id, member_role, operation_id")
      .eq("event_id", eventId)
      .order("created_at", { ascending: false });
    if (error) throw error;

    const ids = (data || []).map(function (m) { return m.user_id; }).filter(Boolean);
    const opIds = (data || []).map(function (m) { return m.operation_id; }).filter(Boolean);

    var userMap = {};
    if (ids.length) {
      const { data: users, error: uerr } = await client
        .from("users")
        .select("id, email, full_name, role")
        .in("id", ids);
      if (uerr) throw uerr;
      (users || []).forEach(function (u) { userMap[u.id] = u; });
    }

    var opMap = {};
    if (opIds.length) {
      const uniqueOps = opIds.filter(function (id, i) { return opIds.indexOf(id) === i; });
      const { data: ops, error: oerr } = await client
        .from("operations")
        .select("id, name, code")
        .in("id", uniqueOps);
      if (oerr) throw oerr;
      (ops || []).forEach(function (o) { opMap[o.id] = o; });
    }

    return (data || []).map(function (m) {
      return {
        id: m.id,
        event_id: m.event_id,
        user_id: m.user_id,
        member_role: m.member_role,
        operation_id: m.operation_id,
        user: userMap[m.user_id] || null,
        operation: m.operation_id ? (opMap[m.operation_id] || null) : null,
      };
    });
  }

  async function listActiveOperations() {
    const client = getClient();
    const { data, error } = await client
      .from("operations")
      .select("id, name, code, sort_order")
      .eq("is_active", true)
      .order("sort_order", { ascending: true })
      .order("name", { ascending: true });
    if (error) throw error;
    return data || [];
  }

  async function assignMember(eventId, userId, memberRole, me, operationId) {
    if (!eventId || !userId || !memberRole) throw new Error("Missing assignment fields.");
    if (memberRole === "manager" && !operationId) {
      throw new Error("Select an operation for this manager (Decor, Food, Photography, …).");
    }
    const client = getClient();
    const orgId = me && me.organization_id ? me.organization_id : null;
    if (!orgId && me.role !== "platform_owner") {
      throw new Error("Organization context missing.");
    }

    let organizationId = orgId;
    if (!organizationId) {
      const { data: e, error: eerr } = await client
        .from("events")
        .select("organization_id")
        .eq("id", eventId)
        .single();
      if (eerr) throw eerr;
      organizationId = e.organization_id;
    }

    const { data, error } = await client
      .from("event_members")
      .upsert(
        {
          organization_id: organizationId,
          event_id: eventId,
          user_id: userId,
          member_role: memberRole,
          operation_id: memberRole === "client" ? null : (operationId || null),
        },
        { onConflict: "event_id,user_id" }
      )
      .select("*")
      .single();
    if (error) throw error;
    return data;
  }

  async function removeMember(memberId) {
    const client = getClient();
    const { error } = await client
      .from("event_members")
      .delete()
      .eq("id", memberId);
    if (error) throw error;
    return true;
  }

  async function getMyEventMembership(eventId) {
    if (!eventId) return null;
    const client = getClient();
    const session = await MaxxAuth.getSession();
    const uid = session && session.user ? session.user.id : null;
    if (!uid) return null;
    const { data, error } = await client
      .from("event_members")
      .select("id, event_id, user_id, member_role, operation_id")
      .eq("event_id", eventId)
      .eq("user_id", uid)
      .maybeSingle();
    if (error) throw error;
    if (!data) return null;

    var operation = null;
    if (data.operation_id) {
      const { data: op, error: oerr } = await client
        .from("operations")
        .select("id, name, code")
        .eq("id", data.operation_id)
        .maybeSingle();
      if (oerr) throw oerr;
      operation = op || null;
    }
    return Object.assign({}, data, { operation: operation });
  }

  async function listUploads(eventId) {
    const client = getClient();
    let q = client
      .from("event_uploads")
      .select("id, event_id, upload_type, file_url, file_path, caption, uploaded_by, operation_id, created_at")
      .order("created_at", { ascending: false });
    if (eventId) q = q.eq("event_id", eventId);
    const { data, error } = await q;
    if (error) throw error;
    const rows = data || [];
    const ids = rows.map(function (r) { return r.uploaded_by; }).filter(Boolean);
    const opIds = rows.map(function (r) { return r.operation_id; }).filter(Boolean);

    var userMap = {};
    if (ids.length) {
      const unique = ids.filter(function (id, i) { return ids.indexOf(id) === i; });
      const { data: users, error: uerr } = await client
        .from("users")
        .select("id, email, full_name, role")
        .in("id", unique);
      if (uerr) throw uerr;
      (users || []).forEach(function (u) { userMap[u.id] = u; });
    }

    var opMap = {};
    if (opIds.length) {
      const uniqueOps = opIds.filter(function (id, i) { return opIds.indexOf(id) === i; });
      const { data: ops, error: oerr } = await client
        .from("operations")
        .select("id, name, code")
        .in("id", uniqueOps);
      if (oerr) throw oerr;
      (ops || []).forEach(function (o) { opMap[o.id] = o; });
    }

    return rows.map(function (r) {
      return Object.assign({}, r, {
        uploader: userMap[r.uploaded_by] || null,
        operation: r.operation_id ? (opMap[r.operation_id] || null) : null,
      });
    });
  }

  async function createUpload(input) {
    const client = getClient();
    const eventId = input.eventId;
    if (!eventId) throw new Error("Select an event.");
    if (!input.file && !input.caption) throw new Error("Add a file or caption.");

    const session = await MaxxAuth.getSession();
    const uploadedBy = session && session.user ? session.user.id : null;

    let operationId = input.operationId || null;
    if (!operationId && uploadedBy) {
      const membership = await getMyEventMembership(eventId);
      if (membership && membership.operation_id) {
        operationId = membership.operation_id;
      }
    }

    let fileUrl = null;
    let filePath = null;
    if (input.file) {
      const safe = String(input.file.name || "upload.bin").replace(/[^a-zA-Z0-9._-]/g, "_");
      filePath = eventId + "/" + Date.now() + "_" + safe;
      const { error: uerr } = await client.storage
        .from("event-uploads")
        .upload(filePath, input.file, { upsert: false });
      if (uerr) throw uerr;

      const out = client.storage.from("event-uploads").getPublicUrl(filePath);
      fileUrl = out && out.data ? out.data.publicUrl : null;
    }

    const uploadType = input.uploadType || (input.file ? "document" : "note");
    const { data, error } = await client
      .from("event_uploads")
      .insert({
        organization_id: input.organizationId,
        event_id: eventId,
        uploaded_by: uploadedBy,
        operation_id: operationId,
        upload_type: uploadType,
        file_url: fileUrl,
        file_path: filePath,
        caption: input.caption || null,
      })
      .select("*")
      .single();
    if (error) throw error;
    return data;
  }

  function subscribeUploads(onChange) {
    const client = getClient();
    const channel = client
      .channel("maxx-event-uploads-changes")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "event_uploads" },
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

  window.MaxxEventFeed = {
    canAssign,
    canUpload,
    listAccessibleEvents,
    listAssignableUsers,
    listActiveOperations,
    listEventMembers,
    getMyEventMembership,
    assignMember,
    removeMember,
    listUploads,
    createUpload,
    subscribeUploads,
    unsubscribe,
  };
})();