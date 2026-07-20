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

  window.MaxxAuth = {
    client,
    getSession,
    signIn,
    signOut,
    getMe,
    requireAuth,
  };
})();
