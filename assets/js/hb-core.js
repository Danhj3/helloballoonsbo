(function () {
  const HB = {};

  HB.brand = {
    logoUrl: "https://i.imgur.com/41t5f0K.png",
    heroImage: "https://i.imgur.com/7y7PZ9i.jpeg",
    colors: {
      pink: "#E2557B",
      teal: "#0CA494",
      yellow: "#D6D234",
      ink: "#263238",
      soft: "#FFF8FB"
    }
  };

  HB.config = function config() {
    return window.HELLO_BALLOONS_SUPABASE || {};
  };

  HB.baseLocation = function baseLocation() {
    return window.HELLO_BALLOONS_BASE_LOCATION || {
      name: "Base Hello Balloons",
      address: "El Palmar, Santa Cruz de la Sierra",
      latitude: -17.830615,
      longitude: -63.157275
    };
  };

  HB.isConfigured = function isConfigured() {
    const current = HB.config();
    return Boolean(
      current.url &&
      current.anonKey &&
      !current.url.includes("TU-PROYECTO") &&
      !current.anonKey.includes("TU_ANON_KEY")
    );
  };

  HB.client = function client() {
    if (!HB.isConfigured() || !window.supabase) {
      return null;
    }
    if (!window.__helloBalloonsClient) {
      window.__helloBalloonsClient = window.supabase.createClient(HB.config().url, HB.config().anonKey);
    }
    return window.__helloBalloonsClient;
  };

  HB.money = function money(value, currency = "BOB") {
    const amount = Number(value || 0);
    if (!amount) return "Bs. 0";
    if (currency === "BOB") {
      return `Bs. ${amount.toLocaleString("es-BO", { maximumFractionDigits: 2 })}`;
    }
    return `${amount.toLocaleString("es-BO", { maximumFractionDigits: 2 })} ${currency}`;
  };

  HB.escapeHtml = function escapeHtml(value) {
    return String(value || "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  };

  HB.escapeAttr = function escapeAttr(value) {
    return HB.escapeHtml(value).replaceAll("`", "&#096;");
  };

  HB.slug = function slug(value) {
    return String(value || "")
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/(^-|-$)/g, "");
  };

  HB.roundTo = function roundTo(value, step = 10) {
    const numeric = Number(value || 0);
    const rounding = Number(step || 1);
    return Math.ceil(numeric / rounding) * rounding;
  };

  HB.haversineKm = function haversineKm(origin, destination) {
    const toRad = (value) => (Number(value) * Math.PI) / 180;
    const radiusKm = 6371;
    const dLat = toRad(destination.latitude - origin.latitude);
    const dLon = toRad(destination.longitude - origin.longitude);
    const lat1 = toRad(origin.latitude);
    const lat2 = toRad(destination.latitude);
    const x = Math.sin(dLat / 2) ** 2 + Math.sin(dLon / 2) ** 2 * Math.cos(lat1) * Math.cos(lat2);
    return 2 * radiusKm * Math.asin(Math.sqrt(x));
  };

  HB.parseMapsInput = function parseMapsInput(value) {
    const input = String(value || "").trim();
    if (!input) return null;

    const decoded = (() => {
      try { return decodeURIComponent(input); } catch { return input; }
    })();

    const patterns = [
      /@(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)/,
      /!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/,
      /[?&]q=(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)/,
      /[?&]query=(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)/,
      /(-?\d{1,2}\.\d{4,}),\s*(-?\d{1,3}\.\d{4,})/
    ];

    for (const pattern of patterns) {
      const match = decoded.match(pattern);
      if (match) {
        const latitude = Number(match[1]);
        const longitude = Number(match[2]);
        if (Number.isFinite(latitude) && Number.isFinite(longitude) && Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180) {
          return { latitude, longitude, source: "parsed_locally", originalInput: input };
        }
      }
    }

    if (/maps\.app\.goo\.gl|goo\.gl\/maps|google\.com\/maps/i.test(input)) {
      return { needsServerResolve: true, mapsUrl: input, source: "needs_server_resolve", originalInput: input };
    }

    return { addressText: input, source: "address_text", originalInput: input };
  };

  HB.transportFallback = function transportFallback({ destination, loadType = "medium" }) {
    const origin = HB.baseLocation();
    const oneWayKm = HB.haversineKm(origin, destination) * 1.25;
    const roundTripKm = oneWayKm * 2;
    const loadSurcharge = loadType === "heavy" ? 45 : loadType === "light" ? 0 : 20;
    const raw = 20 + roundTripKm * 3 + loadSurcharge + 15;
    return {
      provider: "calculo_local_aproximado",
      distanceKmOneWay: Number(oneWayKm.toFixed(2)),
      roundTripKm: Number(roundTripKm.toFixed(2)),
      durationMinutesOneWay: Math.round((oneWayKm / 25) * 60),
      suggestedCost: HB.roundTo(raw, 10),
      loadType
    };
  };

  HB.margin = function margin(cost, price, targetMargin = 0.5) {
    const totalCost = Number(cost || 0);
    const finalPrice = Number(price || 0);
    const minimumPrice = totalCost / (1 - targetMargin);
    const expectedProfit = finalPrice - totalCost;
    const marginPercent = finalPrice > 0 ? expectedProfit / finalPrice : 0;
    const status = !finalPrice
      ? "sin_precio"
      : marginPercent >= targetMargin
        ? "verde"
        : marginPercent >= 0.35
          ? "amarillo"
          : "rojo";
    return { totalCost, minimumPrice, expectedProfit, marginPercent, status };
  };

  HB.signIn = async function signIn(email, password) {
    const client = HB.client();
    if (!client) throw new Error("Configura la anon key publica de Supabase.");
    const { data, error } = await client.auth.signInWithPassword({ email, password });
    if (error) throw error;
    return data;
  };

  HB.signOut = async function signOut() {
    const client = HB.client();
    if (client) await client.auth.signOut();
  };

  HB.getSession = async function getSession() {
    const client = HB.client();
    if (!client) return null;
    const { data } = await client.auth.getSession();
    return data.session;
  };

  HB.invoke = async function invoke(functionName, body) {
    const client = HB.client();
    if (!client) throw new Error("Configura Supabase antes de usar funciones.");
    const { data, error } = await client.functions.invoke(functionName, { body });
    if (error) throw error;
    return data;
  };

  HB.fetchServices = async function fetchServices() {
    const fallback = [
      { id: "decoracion-media", name: "Decoracion tematica media", description: "Panel, mesa, cilindros, globos y detalles personalizados.", base_price: 1250, currency: "BOB", image_url: HB.brand.heroImage, is_featured: true },
      { id: "arco-organico", name: "Arco organico de globos", description: "Arco para ingreso, mesa principal o backdrop con paleta personalizada.", base_price: 450, currency: "BOB", image_url: HB.brand.heroImage, is_featured: true },
      { id: "bouquet-globos", name: "Bouquet de globos", description: "Detalle personalizado con globos, colores y mensaje.", base_price: 180, currency: "BOB", image_url: HB.brand.heroImage, is_featured: false }
    ];

    const client = HB.client();
    if (!client) return fallback;
    const { data, error } = await client
      .from("services")
      .select("id, name, description, base_price, currency, image_url, is_featured")
      .eq("is_active", true)
      .order("is_featured", { ascending: false })
      .order("display_order", { ascending: true });
    if (error) return fallback;
    return data && data.length ? data : fallback;
  };

  HB.fetchQuotes = async function fetchQuotes() {
    const client = HB.client();
    if (!client) return [];
    const { data, error } = await client
      .from("quotes")
      .select("id, quote_number, status, total_cost, minimum_price, suggested_price, final_price, expected_profit, margin_percent, profitability_status, created_at")
      .order("created_at", { ascending: false })
      .limit(20);
    if (error) throw error;
    return data || [];
  };

  HB.fetchInventory = async function fetchInventory() {
    const client = HB.client();
    if (!client) return [];
    const { data, error } = await client
      .from("inventory_items")
      .select("id, code, name, current_color, current_status, current_location, condition_notes, image_url, updated_at")
      .eq("is_active", true)
      .order("name", { ascending: true });
    if (error) throw error;
    return data || [];
  };

  HB.renderInternalNav = function renderInternalNav() {
    const current = window.location.pathname.split('/').pop() || 'dashboard.html';
    const internalPages = [
      'dashboard.html',
      'agenda.html',
      'analytics.html',
      'admin-galeria.html',
      'inventario-app.html',
      'rutas.html',
      'cotizador.html',
      'memoria-eventos.html'
    ];

    if (!internalPages.includes(current)) return;

    const nav = document.querySelector('.hb-nav .hb-nav-inner');
    if (!nav) return;

    const items = [
      { href: 'dashboard.html', label: 'Inicio' },
      { href: 'agenda.html', label: 'Agenda' },
      { href: 'analytics.html', label: 'Analytics' },
      { href: 'admin-galeria.html', label: 'Galería' },
      { href: 'inventario-app.html', label: 'Inventario' },
      { href: 'rutas.html', label: 'Rutas' },
      { href: 'cotizador.html', label: 'Cotizador' },
      { href: 'memoria-eventos.html', label: 'Memoria' },
      { href: 'index.html', label: 'Web pública' }
    ];

    nav.innerHTML = `
      <a class="hb-brand" href="dashboard.html">
        <img src="${HB.brand.logoUrl}" alt="Hello Balloons" />
        <span>Dashboard</span>
      </a>
      <div class="hb-nav-links">
        ${items.map(item => `<a class="${item.href === current ? 'active' : ''}" href="${item.href}">${item.label}</a>`).join('')}
      </div>
    `;
  };

  window.HB = HB;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', HB.renderInternalNav);
  } else {
    HB.renderInternalNav();
  }
})();