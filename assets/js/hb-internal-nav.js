(function () {
  const current = window.location.pathname.split('/').pop() || 'dashboard.html';
  const items = [
    { href: 'dashboard.html', label: 'Inicio' },
    { href: 'admin.html', label: 'Pedidos' },
    { href: 'admin-galeria.html', label: 'Galería' },
    { href: 'inventario-app.html', label: 'Inventario' },
    { href: 'rutas.html', label: 'Rutas' },
    { href: 'cotizador.html', label: 'Cotizador' },
    { href: 'memoria-eventos.html', label: 'Memoria' },
    { href: 'index.html', label: 'Web pública' }
  ];

  function renderInternalNav() {
    const nav = document.querySelector('.hb-nav .hb-nav-inner');
    if (!nav) return;

    const links = items.map(item => {
      const active = item.href === current ? 'active' : '';
      return `<a class="${active}" href="${item.href}">${item.label}</a>`;
    }).join('');

    nav.innerHTML = `
      <a class="hb-brand" href="dashboard.html">
        <img src="https://i.imgur.com/41t5f0K.png" alt="Hello Balloons" />
        <span>Dashboard</span>
      </a>
      <div class="hb-nav-links">${links}</div>
    `;
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', renderInternalNav);
  } else {
    renderInternalNav();
  }
})();
