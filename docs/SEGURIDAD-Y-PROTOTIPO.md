# Hello Balloons — Prototipo seguro con Supabase, IA, transporte e inventario

Este documento describe la primera capa segura del sistema de Hello Balloons. La idea es convertir la web actual en una oficina operativa para cotizar, controlar inventario, calcular transporte, planificar rutas y usar IA sin exponer claves privadas.

## 1. Arquitectura propuesta

```text
Web publica / panel admin
        ↓
Supabase Auth + RLS
        ↓
Supabase Postgres
        ↓
Supabase Edge Functions
        ↓
OpenAI API / Google Maps Routes API
```

La web actual se mantiene. Esta capa agrega seguridad y estructura operativa sin borrar `index.html`, `pedidos.html`, `admin.html` ni `inventario.html`.

## 2. Archivos agregados

```text
supabase/migrations/20260520_secure_operations_prototype.sql
supabase/functions/_shared/cors.ts
supabase/functions/transport-estimate/index.ts
supabase/functions/ai-quote-assistant/index.ts
docs/SEGURIDAD-Y-PROTOTIPO.md
```

## 3. Seguridad desde el inicio

La migracion agrega roles internos:

```text
admin
Decoradora
ventas
inventario
logistica
```

En la base se guardan como enum:

```text
admin
decoradora
ventas
inventario
logistica
```

Las tablas nuevas tienen Row Level Security activado. La regla central es:

- visitantes anonimos pueden ver servicios activos;
- visitantes anonimos pueden crear pedidos solo por la funcion validada `create_order_with_items`;
- administracion, cotizaciones, rutas, inventario e IA requieren usuario autenticado con rol;
- claves privadas se guardan como secretos de Supabase Edge Functions, nunca en JavaScript del navegador.

## 4. Orden de instalacion en Supabase

Primero ejecutar el esquema actual:

```sql
supabase/schema.sql
```

Luego ejecutar:

```sql
supabase/migrations/20260520_secure_operations_prototype.sql
```

Despues crear el usuario administrador en Supabase Authentication y ejecutar:

```sql
insert into public.user_roles (user_id, role)
select id, 'admin'::public.app_role
from auth.users
where email = 'TU-CORREO-ADMIN';
```

Tambien configurar la base de salida de Hello Balloons:

```sql
update public.business_locations
set
  address_text = 'TU DIRECCION REAL',
  latitude = -17.0000000,
  longitude = -63.0000000
where is_default = true;
```

## 5. Modulo de cotizacion rentable

La tabla `quotes` calcula automaticamente:

```text
costo total
precio minimo rentable
ganancia esperada
margen porcentual
estado de rentabilidad
```

La regla inicial es 50/50:

```text
Costos maximos: 50%
Ganancia objetivo: 50%
Precio minimo rentable = costo total / (1 - margen objetivo)
```

Ejemplo:

```text
Costo total: Bs. 440
Margen objetivo: 50%
Precio minimo rentable: Bs. 880
```

El semaforo queda asi:

```text
verde: cumple el margen objetivo
amarillo: margen entre 35% y 49%
rojo: margen menor a 35%
sin_precio: aun no tiene precio final ni sugerido
```

## 6. Modulo de transporte

La tabla `transport_rate_profiles` contiene tarifas editables:

```text
tarifa base
costo por km ida y vuelta
costo por minuto
recargo por carga liviana/media/pesada
margen de seguridad
redondeo
```

La funcion Edge `transport-estimate` calcula:

```text
distancia ida
distancia ida y vuelta
tiempo estimado
costo sugerido
proveedor usado
```

Si existe `GOOGLE_MAPS_API_KEY`, usa Google Routes. Si no existe, usa un calculo aproximado por coordenadas para prototipo.

Solicitud ejemplo:

```json
{
  "orderId": "uuid-opcional",
  "quoteId": "uuid-opcional",
  "destination": {
    "addressText": "Salon de eventos, Santa Cruz",
    "latitude": -17.7833,
    "longitude": -63.1821,
    "zoneName": "Centro"
  },
  "loadType": "medium",
  "useGoogleRoutes": true
}
```

## 7. Modulo de rutas diarias

Las tablas principales son:

```text
daily_routes
daily_route_stops
vehicles
```

Sirven para planificar 3 o 4 decoraciones en un dia. El sistema podra ordenar paradas, calcular tiempos, detectar riesgos y ayudar a llegar a tiempo con menor costo.

## 8. Modulo de inventario

Las tablas principales son:

```text
inventory_categories
inventory_items
inventory_status_history
inventory_reservations
event_inventory_items
```

Cada mueble puede tener:

```text
codigo
nombre
color actual
estado actual
ubicacion actual
condicion
foto
historial
reservas
```

Estados permitidos:

```text
available
reserved
in_use
maintenance
requires_paint
damaged
lost
external_rental
out_of_service
```

La tabla `inventory_reservations` impide solapamientos para el mismo item cuando esta reservado o en uso. Eso evita vender el mismo panel/mueble para dos eventos incompatibles.

## 9. IA segura

La funcion `ai-quote-assistant` usa OpenAI desde servidor. No se debe llamar OpenAI directamente desde el navegador.

La IA puede ayudar a:

```text
ordenar pedidos desordenados
detectar informacion faltante
advertir riesgos de margen
sugerir mensaje para WhatsApp
marcar inventario a verificar
advertir inconsistencias de color
```

La IA no debe ser fuente de verdad del inventario. La fuente de verdad es Supabase.

## 10. Secretos necesarios

En Supabase Edge Functions configurar:

```bash
supabase secrets set OPENAI_API_KEY="tu_clave_openai"
supabase secrets set OPENAI_MODEL="gpt-5-mini"
supabase secrets set GOOGLE_MAPS_API_KEY="tu_clave_google_maps"
```

Supabase ya provee normalmente:

```text
SUPABASE_URL
SUPABASE_SERVICE_ROLE_KEY
```

Nunca subir claves reales a GitHub.

## 11. Siguientes pasos recomendados

1. Ejecutar la migracion en Supabase.
2. Crear usuario administrador y asignarle rol `admin`.
3. Configurar la direccion base real con latitud y longitud.
4. Desplegar Edge Functions.
5. Crear una pantalla `cotizador.html` conectada a `quotes`, `transport-estimate` y `ai-quote-assistant`.
6. Crear una pantalla movil `inventario-admin.html` para que el trabajador actualice color, estado, ubicacion y foto.
7. Crear una pantalla `rutas.html` para ver eventos del dia, horarios, conflictos y rutas sugeridas.
