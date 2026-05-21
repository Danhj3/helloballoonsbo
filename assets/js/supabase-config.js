window.HELLO_BALLOONS_SUPABASE = {
  url: "https://dcyhfiwuyjydqprkljcu.supabase.co",
  anonKey: "sb_publishable_ieDJVa8mSfhW7ffs-ke8dw_8mEFOp6T"
};

window.HELLO_BALLOONS_BASE_LOCATION = {
  name: "Base Hello Balloons - El Palmar",
  address: "El Palmar, Santa Cruz de la Sierra",
  latitude: -17.830615,
  longitude: -63.157275,
  mapsUrl: "https://maps.app.goo.gl/4rkmYGWY7naXQaFf9"
};

(function () {
  const internalPages = [
    "dashboard.html",
    "admin-galeria.html",
    "inventario-app.html",
    "rutas.html",
    "cotizador.html",
    "memoria-eventos.html"
  ];

  const items = [
    { href: "dashboard.html", label: "Analytics" },
    { href: "admin-galeria.html", label: "Galería" },
    { href: "inventario-app.html", label: "Inventario" },
    { href: "rutas.html", label: "Rutas" },
    { href: "cotizador.html", label: "Cotizador" },
    { href: "memoria-eventos.html", label: "Memoria" },
    { href: "index.html", label: "Web pública" }
  ];

  function currentFileName() {
    const current = window.location.pathname.split("/").pop();
    return current || "dashboard.html";
  }

  function renderInternalNavigation() {
    const current = currentFileName();
    if (!internalPages.includes(current)) return;

    const nav = document.querySelector(".hb-nav .hb-nav-inner");
    if (!nav) return;

    nav.innerHTML = `
      <a class="hb-brand" href="dashboard.html">
        <img src="https://i.imgur.com/41t5f0K.png" alt="Hello Balloons" />
        <span>Dashboard</span>
      </a>
      <div class="hb-nav-links">
        ${items.map((item) => `<a class="${item.href === current ? "active" : ""}" href="${item.href}">${item.label}</a>`).join("")}
      </div>
    `;
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", renderInternalNavigation);
  } else {
    renderInternalNavigation();
  }
})();
