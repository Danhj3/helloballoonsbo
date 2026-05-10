(function () {
  const defaultImage = "https://i.imgur.com/7y7PZ9i.jpeg";

  const fallbackCategories = [
    { id: "decoracion", name: "Decoracion", slug: "decoracion" },
    { id: "mobiliario", name: "Mobiliario", slug: "mobiliario" },
    { id: "extras", name: "Extras", slug: "extras" }
  ];

  const fallbackServices = [
    {
      id: "arco-organico",
      category_id: "decoracion",
      name: "Arco organico de globos",
      description: "Arco para ingreso, mesa principal o backdrop con paleta personalizada.",
      base_price: 450,
      currency: "BOB",
      image_url: defaultImage,
      is_active: true,
      is_featured: true
    },
    {
      id: "decoracion-tematica",
      category_id: "decoracion",
      name: "Decoracion tematica completa",
      description: "Mesa, fondos, globos, accesorios y montaje para cumpleanos o celebraciones.",
      base_price: 1250,
      currency: "BOB",
      image_url: defaultImage,
      is_active: true,
      is_featured: true
    },
    {
      id: "mobiliario-evento",
      category_id: "mobiliario",
      name: "Mobiliario para evento",
      description: "Paneles, cilindros, bases, mesas y accesorios segun disponibilidad.",
      base_price: 280,
      currency: "BOB",
      image_url: "https://i.imgur.com/41t5f0K.png",
      is_active: true,
      is_featured: false
    },
    {
      id: "bouquet-globos",
      category_id: "extras",
      name: "Bouquet de globos",
      description: "Detalle personalizado con globos, colores y mensaje a eleccion.",
      base_price: 180,
      currency: "BOB",
      image_url: defaultImage,
      is_active: true,
      is_featured: false
    }
  ];

  function config() {
    return window.HELLO_BALLOONS_SUPABASE || {};
  }

  function isConfigured() {
    const current = config();
    return Boolean(
      current.url &&
      current.anonKey &&
      !current.url.includes("TU-PROYECTO") &&
      !current.anonKey.includes("TU_ANON_KEY")
    );
  }

  function getClient() {
    if (!isConfigured() || !window.supabase) {
      return null;
    }

    if (!window.__helloBalloonsClient) {
      window.__helloBalloonsClient = window.supabase.createClient(config().url, config().anonKey);
    }

    return window.__helloBalloonsClient;
  }

  function formatPrice(value, currency) {
    const amount = Number(value || 0);
    if (!amount) {
      return "A cotizar";
    }
    return `${amount.toLocaleString("es-BO")} ${currency || "BOB"}`;
  }

  function escapeHtml(value) {
    return String(value || "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  function escapeAttr(value) {
    return escapeHtml(value).replaceAll("`", "&#096;");
  }

  function toFallbackResult(error) {
    return {
      services: fallbackServices,
      categories: fallbackCategories,
      error
    };
  }

  async function fetchServices() {
    const client = getClient();
    if (!client) {
      return toFallbackResult(null);
    }

    const { data, error } = await client
      .from("services")
      .select("id, category_id, name, description, base_price, currency, image_url, is_active, is_featured, service_categories(name, slug)")
      .eq("is_active", true)
      .order("is_featured", { ascending: false })
      .order("display_order", { ascending: true })
      .order("name", { ascending: true });

    if (error) {
      console.warn("No se pudieron cargar servicios:", error.message);
      return toFallbackResult(error);
    }

    return {
      services: data && data.length ? data : fallbackServices,
      categories: fallbackCategories,
      error: null
    };
  }

  async function fetchCategories() {
    const client = getClient();
    if (!client) {
      return { categories: fallbackCategories, error: null };
    }

    const { data, error } = await client
      .from("service_categories")
      .select("id, name, slug")
      .eq("is_active", true)
      .order("display_order", { ascending: true })
      .order("name", { ascending: true });

    if (error) {
      console.warn("No se pudieron cargar categorias:", error.message);
      return { categories: fallbackCategories, error };
    }

    return { categories: data && data.length ? data : fallbackCategories, error: null };
  }

  async function createOrder(order, items) {
    const client = getClient();
    if (!client) {
      throw new Error("Supabase no esta configurado.");
    }

    const { data: orderRow, error: orderError } = await client
      .rpc("create_order_with_items", {
        order_payload: order,
        items_payload: items || []
      })
      .single();

    if (orderError) {
      throw orderError;
    }

    return orderRow;
  }

  async function signIn(email, password) {
    const client = getClient();
    if (!client) {
      throw new Error("Configura Supabase antes de iniciar sesion.");
    }
    const { data, error } = await client.auth.signInWithPassword({ email, password });
    if (error) {
      throw error;
    }
    return data;
  }

  async function signOut() {
    const client = getClient();
    if (!client) {
      return;
    }
    await client.auth.signOut();
  }

  async function getSession() {
    const client = getClient();
    if (!client) {
      return null;
    }
    const { data } = await client.auth.getSession();
    return data.session;
  }

  async function fetchAdminServices() {
    const client = getClient();
    if (!client) {
      return fallbackServices;
    }
    const { data, error } = await client
      .from("services")
      .select("id, category_id, name, description, base_price, currency, image_url, is_active, is_featured, display_order")
      .order("display_order", { ascending: true })
      .order("name", { ascending: true });
    if (error) {
      throw error;
    }
    return data || [];
  }

  async function upsertService(service) {
    const client = getClient();
    if (!client) {
      throw new Error("Supabase no esta configurado.");
    }

    const payload = {
      category_id: service.category_id || null,
      name: service.name,
      description: service.description || null,
      base_price: Number(service.base_price || 0),
      currency: service.currency || "BOB",
      image_url: service.image_url || null,
      is_active: Boolean(service.is_active),
      is_featured: Boolean(service.is_featured),
      display_order: Number(service.display_order || 0)
    };

    if (service.id) {
      payload.id = service.id;
    }

    const { data, error } = await client
      .from("services")
      .upsert(payload)
      .select("id")
      .single();

    if (error) {
      throw error;
    }

    return data;
  }

  async function updateOrderStatus(orderId, status) {
    const client = getClient();
    if (!client) {
      throw new Error("Supabase no esta configurado.");
    }
    const { error } = await client.from("orders").update({ status }).eq("id", orderId);
    if (error) {
      throw error;
    }
  }

  async function fetchOrders() {
    const client = getClient();
    if (!client) {
      return [];
    }
    const { data, error } = await client
      .from("orders")
      .select("id, order_number, client_name, client_phone, event_date, event_type, total_amount, status, created_at")
      .order("created_at", { ascending: false })
      .limit(50);
    if (error) {
      throw error;
    }
    return data || [];
  }

  window.HelloBalloonsData = {
    defaultImage,
    fallbackServices,
    fallbackCategories,
    isConfigured,
    getClient,
    formatPrice,
    escapeHtml,
    escapeAttr,
    fetchServices,
    fetchCategories,
    createOrder,
    signIn,
    signOut,
    getSession,
    fetchAdminServices,
    upsertService,
    updateOrderStatus,
    fetchOrders
  };
})();
