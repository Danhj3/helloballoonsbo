create extension if not exists pgcrypto;

create table if not exists public.service_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  description text,
  display_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.services (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.service_categories(id) on delete set null,
  name text not null,
  description text,
  base_price numeric(10,2) not null default 0,
  currency text not null default 'BOB',
  image_url text,
  is_active boolean not null default true,
  is_featured boolean not null default false,
  display_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique default ('HB-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(gen_random_uuid()::text, 1, 6))),
  client_name text not null,
  client_phone text not null,
  client_email text,
  event_date date not null,
  event_type text not null,
  event_address text,
  notes text,
  total_amount numeric(10,2) not null default 0,
  currency text not null default 'BOB',
  status text not null default 'new' check (status in ('new', 'quoted', 'confirmed', 'delivered', 'cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  service_id uuid references public.services(id) on delete set null,
  quantity integer not null default 1 check (quantity > 0),
  unit_price numeric(10,2) not null default 0,
  line_total numeric(10,2) not null default 0,
  created_at timestamptz not null default now()
);

create or replace function public.create_order_with_items(order_payload jsonb, items_payload jsonb default '[]'::jsonb)
returns table(id uuid, order_number text)
language plpgsql
security definer
set search_path = public
as $$
declare
  inserted_order public.orders%rowtype;
  item jsonb;
  raw_service_id text;
  parsed_service_id uuid;
begin
  insert into public.orders (
    client_name,
    client_phone,
    client_email,
    event_date,
    event_type,
    event_address,
    notes,
    total_amount,
    currency,
    status
  )
  values (
    order_payload->>'client_name',
    order_payload->>'client_phone',
    nullif(order_payload->>'client_email', ''),
    (order_payload->>'event_date')::date,
    order_payload->>'event_type',
    nullif(order_payload->>'event_address', ''),
    nullif(order_payload->>'notes', ''),
    coalesce(nullif(order_payload->>'total_amount', '')::numeric, 0),
    coalesce(nullif(order_payload->>'currency', ''), 'BOB'),
    coalesce(nullif(order_payload->>'status', ''), 'new')
  )
  returning * into inserted_order;

  for item in select * from jsonb_array_elements(coalesce(items_payload, '[]'::jsonb))
  loop
    raw_service_id := item->>'service_id';
    parsed_service_id := null;

    if raw_service_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      parsed_service_id := raw_service_id::uuid;
    end if;

    insert into public.order_items (
      order_id,
      service_id,
      quantity,
      unit_price,
      line_total
    )
    values (
      inserted_order.id,
      parsed_service_id,
      coalesce(nullif(item->>'quantity', '')::integer, 1),
      coalesce(nullif(item->>'unit_price', '')::numeric, 0),
      coalesce(nullif(item->>'line_total', '')::numeric, 0)
    );
  end loop;

  return query select inserted_order.id, inserted_order.order_number;
end;
$$;

grant execute on function public.create_order_with_items(jsonb, jsonb) to anon, authenticated;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_service_categories_updated_at on public.service_categories;
create trigger set_service_categories_updated_at
before update on public.service_categories
for each row execute function public.set_updated_at();

drop trigger if exists set_services_updated_at on public.services;
create trigger set_services_updated_at
before update on public.services
for each row execute function public.set_updated_at();

drop trigger if exists set_orders_updated_at on public.orders;
create trigger set_orders_updated_at
before update on public.orders
for each row execute function public.set_updated_at();

alter table public.service_categories enable row level security;
alter table public.services enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

drop policy if exists "Public can read active categories" on public.service_categories;
create policy "Public can read active categories"
on public.service_categories
for select
to anon, authenticated
using (is_active = true or auth.role() = 'authenticated');

drop policy if exists "Admins manage categories" on public.service_categories;
create policy "Admins manage categories"
on public.service_categories
for all
to authenticated
using (true)
with check (true);

drop policy if exists "Public can read active services" on public.services;
create policy "Public can read active services"
on public.services
for select
to anon, authenticated
using (is_active = true or auth.role() = 'authenticated');

drop policy if exists "Admins manage services" on public.services;
create policy "Admins manage services"
on public.services
for all
to authenticated
using (true)
with check (true);

drop policy if exists "Public can create orders" on public.orders;
create policy "Public can create orders"
on public.orders
for insert
to anon, authenticated
with check (true);

drop policy if exists "Admins read orders" on public.orders;
create policy "Admins read orders"
on public.orders
for select
to authenticated
using (true);

drop policy if exists "Admins update orders" on public.orders;
create policy "Admins update orders"
on public.orders
for update
to authenticated
using (true)
with check (true);

drop policy if exists "Public can create order items" on public.order_items;
create policy "Public can create order items"
on public.order_items
for insert
to anon, authenticated
with check (true);

drop policy if exists "Admins read order items" on public.order_items;
create policy "Admins read order items"
on public.order_items
for select
to authenticated
using (true);

drop policy if exists "Admins update order items" on public.order_items;
create policy "Admins update order items"
on public.order_items
for all
to authenticated
using (true)
with check (true);

insert into public.service_categories (name, slug, description, display_order)
values
  ('Decoracion', 'decoracion', 'Decoraciones completas y montajes principales', 1),
  ('Mobiliario', 'mobiliario', 'Paneles, mesas, bases y estructuras para eventos', 2),
  ('Extras', 'extras', 'Bouquets, accesorios y complementos', 3)
on conflict (slug) do update set
  name = excluded.name,
  description = excluded.description,
  display_order = excluded.display_order,
  is_active = true;

insert into public.services (category_id, name, description, base_price, currency, image_url, is_active, is_featured, display_order)
select category.id, seed.name, seed.description, seed.base_price, 'BOB', seed.image_url, true, seed.is_featured, seed.display_order
from (
  values
    ('decoracion', 'Arco organico de globos', 'Arco para ingreso, mesa principal o backdrop con paleta personalizada.', 450::numeric, 'https://i.imgur.com/7y7PZ9i.jpeg', true, 1),
    ('decoracion', 'Decoracion tematica completa', 'Mesa, fondos, globos, accesorios y montaje para cumpleanos o celebraciones.', 1250::numeric, 'https://i.imgur.com/7y7PZ9i.jpeg', true, 2),
    ('mobiliario', 'Mobiliario para evento', 'Paneles, cilindros, bases, mesas y accesorios segun disponibilidad.', 280::numeric, 'https://i.imgur.com/41t5f0K.png', false, 3),
    ('extras', 'Bouquet de globos', 'Detalle personalizado con globos, colores y mensaje a eleccion.', 180::numeric, 'https://i.imgur.com/7y7PZ9i.jpeg', false, 4)
) as seed(category_slug, name, description, base_price, image_url, is_featured, display_order)
join public.service_categories category on category.slug = seed.category_slug
where not exists (
  select 1
  from public.services existing
  where lower(existing.name) = lower(seed.name)
);
