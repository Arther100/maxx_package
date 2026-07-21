// Creates Auth user + public.users profile from admin UI.
// Deploy: supabase functions deploy admin-create-user
// Secrets: uses project SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type AppRole =
  | "platform_owner"
  | "superadmin"
  | "opsadmin"
  | "manager"
  | "client";

type Body = {
  email?: string;
  password?: string;
  full_name?: string;
  role?: AppRole;
};

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function canAssign(caller: AppRole, target: AppRole): string | null {
  if (!["platform_owner", "superadmin", "opsadmin"].includes(caller)) {
    return "Not allowed to manage users";
  }
  if (target === "platform_owner" && caller !== "platform_owner") {
    return "Only platform_owner can assign platform_owner";
  }
  if (caller === "opsadmin" && (target === "superadmin" || target === "platform_owner")) {
    return "OpsAdmin cannot assign superadmin or platform_owner";
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json(405, { error: "Method not allowed" });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    if (!supabaseUrl || !anonKey || !serviceKey) {
      return json(500, { error: "Missing Supabase environment configuration." });
    }

    const authHeader = req.headers.get("Authorization") || "";
    if (!authHeader.startsWith("Bearer ")) {
      return json(401, { error: "Missing Authorization bearer token." });
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const {
      data: { user: callerAuth },
      error: callerAuthErr,
    } = await userClient.auth.getUser();

    if (callerAuthErr || !callerAuth) {
      return json(401, { error: "Invalid or expired session." });
    }

    const { data: callerProfile, error: callerProfileErr } = await userClient
      .from("users")
      .select("id, email, role, organization_id")
      .eq("id", callerAuth.id)
      .maybeSingle();

    if (callerProfileErr || !callerProfile) {
      return json(403, { error: "Caller profile not found in public.users." });
    }

    const body = (await req.json()) as Body;
    const email = (body.email || "").trim().toLowerCase();
    const password = body.password || "";
    const fullName = (body.full_name || "").trim();
    const role = body.role as AppRole;

    if (!email) return json(400, { error: "Email is required." });
    if (!role) return json(400, { error: "Role is required." });
    if (!password || password.length < 6) {
      return json(400, { error: "Password must be at least 6 characters." });
    }

    const assignErr = canAssign(callerProfile.role as AppRole, role);
    if (assignErr) return json(403, { error: assignErr });

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    let organizationId: string | null = null;
    if (role === "platform_owner") {
      organizationId = null;
    } else if (callerProfile.role === "platform_owner") {
      const { data: org } = await admin
        .from("organizations")
        .select("id")
        .eq("name", "MAXX Events")
        .limit(1)
        .maybeSingle();
      organizationId = org?.id ?? null;
    } else {
      organizationId = callerProfile.organization_id;
    }

    if (role !== "platform_owner" && !organizationId) {
      return json(400, { error: `Organization required for role ${role}` });
    }

    // Create Auth user (or reuse if email already exists).
    let authUserId: string | null = null;
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName || null },
    });

    if (createErr) {
      const msg = (createErr.message || "").toLowerCase();
      const already =
        msg.includes("already") ||
        msg.includes("registered") ||
        msg.includes("exists");

      if (!already) {
        return json(400, { error: createErr.message || "Failed to create Auth user." });
      }

      // Lookup existing auth user by email via listUsers filter.
      const { data: listed, error: listErr } = await admin.auth.admin.listUsers({
        page: 1,
        perPage: 200,
      });
      if (listErr) {
        return json(400, { error: listErr.message || "Auth user exists but lookup failed." });
      }
      const existing = (listed?.users || []).find(
        (u) => (u.email || "").toLowerCase() === email,
      );
      if (!existing) {
        return json(400, {
          error:
            "Auth user already exists but could not be found. Link via email match failed.",
        });
      }
      authUserId = existing.id;

      // Update password so admin-set password works for login.
      const { error: updErr } = await admin.auth.admin.updateUserById(authUserId, {
        password,
        email_confirm: true,
        user_metadata: { full_name: fullName || null },
      });
      if (updErr) {
        return json(400, { error: updErr.message || "Failed to update existing Auth user." });
      }
    } else {
      authUserId = created.user?.id ?? null;
    }

    if (!authUserId) {
      return json(500, { error: "Auth user id missing after create." });
    }

    const { data: profile, error: profileErr } = await admin
      .from("users")
      .upsert(
        {
          id: authUserId,
          email,
          full_name: fullName || null,
          role,
          organization_id: organizationId,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "id" },
      )
      .select("id, email, full_name, role, organization_id")
      .single();

    if (profileErr) {
      return json(400, { error: profileErr.message || "Failed to save profile." });
    }

    return json(200, {
      ok: true,
      user: profile,
      message: "User created. They can sign in with this email and password.",
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected error";
    return json(500, { error: message });
  }
});
