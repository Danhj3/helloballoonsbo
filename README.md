# Helloballoonsbo

Pagina de administracion y pedidos de Hello Balloons.

## Supabase

1. Crea un proyecto en Supabase.
2. Abre el SQL editor y ejecuta `supabase/schema.sql`.
3. En Authentication, crea un usuario admin con email y password.
4. Edita `assets/js/supabase-config.js` con:
   - `url`: Project URL.
   - `anonKey`: public anon key.
5. Abre `admin.html` para cargar servicios, precios e imagenes.
6. Abre `pedidos.html` para recibir pedidos desde la web.

La home (`index.html`) muestra servicios desde Supabase. Si todavia no hay configuracion, usa datos de ejemplo para que la pagina siga visible.
