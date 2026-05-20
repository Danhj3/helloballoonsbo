-- Hello Balloons secure operations prototype
-- Execute this after supabase/schema.sql in the Supabase SQL editor.
-- It extends the current project without removing existing public pages.

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- -----------------------------------------------------------------------------
-- Roles and authorization helpers
-- -----------------------------------------------------------------------------
do $$
begin
  create type public.app_role as enum ('admin', 'decoradora', 'ventas', 'inventario', 'logistica');
exception
  when duplicate_object then null;
end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.app_role not null,
  created_at timestamptz not null default now(),
  unique (user_id, role)
);

create or replace function public.has_role(required_role text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.user_roles ur
    where ur.user_id = auth.uid()
      and ur.role::text = required_role
  );
$$;

create or replace function public.has_any_role(required_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.user_roles ur
    where ur.user_id = auth.uid()
      and ur.role::text = any(required_roles)
  );
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.has_role('admin');
$$;

revoke all on function public.has_role(text) from public, anon;
revoke all on function public.has_any_role(text[]) from public, anon;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.has_role(text) to authenticated;
grant execute on function public.has_any_role(text[]) to authenticated;
grant execute on function public.is_admin() to authenticated;

create or replace function public.handle_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', new.email))
  on conflict (id) do update set
    email = excluded.email,
    updated_at = now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
after insert on auth.users
for each row execute function public.handle_new_user_profile();

-- Run this once in SQL editor after creating your admin user:
-- insert into public.user_roles (user_id, role)
-- select id, 'admin'::public.app_role from auth.users where email = 'TU-CORREO-ADMIN';

-- -----------------------------------------------------------------------------
-- Hardening existing tables
-- -----------------------------------------------------------------------------
alter table public.orders add column if not exists client_id uuid;
alter table public.orders add column if not exists event_start_at timestamptz;
alter table public.orders add column if not exists event_end_at timestamptz;
alter table public.orders add column if not exists setup_duration_minutes integer not null default 120 check (setup_duration_minutes > 0);
alter table public.orders add column if not exists teardown_duration_minutes integer not null default 60 check (teardown_duration_minutes >= 0);
alter table public.orders add column if not exists load_type text not null default 'medium' check (load_type in ('light', 'medium', 'heavy'));
alter table public.orders add column if not exists desired_budget numeric(10,2);

-- Public visitors should create orders through the validated RPC, not by direct table writes.
drop policy if exists "Public can create orders" on public.orders;
drop policy if exists "Public can create order items" on public.order_items;

drop policy if exists "Admins manage categories" on public.service_categories;
create policy "Admins manage categories"
on public.service_categories
for all
to authenticated
using (public.has_any_role(array['admin','decoradora','ventas']))
with check (public.has_any_role(array['admin','decoradora','ventas']));

drop policy if exists "Admins manage services" on public.services;
create policy "Admins manage services"
on public.services
for all
to authenticated
using (public.has_any_role(array['admin','decoradora','ventas']))
with check (public.has_any_role(array['admin','decoradora','ventas']));

drop policy if exists "Admins read orders" on public.orders;
drop policy if exists "Admins update orders" on public.orders;
create policy "Operational staff manage orders"
on public.orders
for all
to authenticated
using (public.has_any_role(array['admin','decoradora','ventas','logistica']))
with check (public.has_any_role(array['admin','decoradora','ventas','logistica']));

drop policy if exists "Admins read order items" on public.order_items;
drop policy if exists "Admins update order items" on public.order_items;
create policy "Operational staff manage order items"
on public.order_items
for all
to authenticated
using (public.has_any_role(array['admin','decoradora','ventas','logistica']))
with check (public.has_any_role(array['admin','decoradora','ventas','logistica']));

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
  requested_status text;
begin
  if nullif(trim(order_payload->>'client_name'), '') is null then
    raise exception 'El nombre del cliente es obligatorio.';
  end if;

  if nullif(trim(order_payload->>'client_phone'), '') is null then
    raise exception 'El telefono del cliente es obligatorio.';
  end if;

  if nullif(order_payload->>'event_date', '') is null then
    raise exception 'La fecha del evento es obligatoria.';
  end if;

  if (order_payload->>'event_date')::date < current_date then
    raise exception 'La fecha del evento no puede estar en el pasado.';
  end if;

  requested_status := coalesce(nullif(order_payload->>'status', ''), 'new');
  if requested_status <> 'new' and not public.has_any_role(array['admin','decoradora','ventas']) then
    requested_status := 'new';
  end if;

  insert into public.orders (
    client_name,
    client_phone,
    client_email,
    event_date,
    event_start_at,
    event_end_at,
    setup_duration_minutes,
    teardown_duration_minutes,
    load_type,
    desired_budget,
    event_type,
    event_address,
    notes,
    total_amount,
    currency,
    status
  )
  values (
    left(trim(order_payload->>'client_name'), 160),
    left(trim(order_payload->>'client_phone'), 60),
    nullif(left(trim(coalesce(order_payload->>'client_email', '')), 160), ''),
    (order_payload->>'event_date')::date,
    nullif(order_payload->>'event_start_at', '')::timestamptz,
    nullif(order_payload->>'event_end_at', '')::timestamptz,
    coalesce(nullif(order_payload->>'setup_duration_minutes', '')::integer, 120),
    coalesce(nullif(order_payload->>'teardown_duration_minutes', '')::integer, 60),
    coalesce(nullif(order_payload->>'load_type', ''), 'medium'),
    nullif(order_payload->>'desired_budget', '')::numeric,
    left(trim(order_payload->>'event_type'), 120),
    nullif(left(trim(coalesce(order_payload->>'event_address', '')), 260), ''),
    nullif(left(trim(coalesce(order_payload->>'notes', '')), 2000), ''),
    coalesce(nullif(order_payload->>'total_amount', '')::numeric, 0),
    coalesce(nullif(order_payload->>'currency', ''), 'BOB'),
    requested_status
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
      greatest(coalesce(nullif(item->>'quantity', '')::integer, 1), 1),
      greatest(coalesce(nullif(item->>'unit_price', '')::numeric, 0), 0),
      greatest(coalesce(nullif(item->>'line_total', '')::numeric, 0), 0)
    );
  end loop;

  return query select inserted_order.id, inserted_order.order_number;
end;
$$;

grant execute on function public.create_order_with_items(jsonb, jsonb) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- Clients, quotes and profitability
-- -----------------------------------------------------------------------------
create table if not exists public.clients (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  phone text not null,
  email text,
  source text,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (phone)
);

alter table public.orders
  drop constraint if exists orders_client_id_fkey;
alter table public.orders
  add constraint orders_client_id_fkey foreign key (client_id) references public.clients(id) on delete set null;

create table if not exists public.quote_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  event_type text,
  package_level text check (package_level in ('basic', 'medium', 'premium', 'custom')),
  default_setup_minutes integer not null default 120,
  default_teardown_minutes integer not null default 60,
  default_staff_count integer not null default 1,
  default_load_type text not null default 'medium' check (default_load_type in ('light','medium','heavy')),
  base_material_cost numeric(10,2) not null default 0,
  base_staff_cost numeric(10,2) not null default 0,
  base_extra_cost numeric(10,2) not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.quotes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id) on delete set null,
  client_id uuid references public.clients(id) on delete set null,
  template_id uuid references public.quote_templates(id) on delete set null,
  quote_number text not null unique default ('COT-HB-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(gen_random_uuid()::text, 1, 6))),
  status text not null default 'draft' check (status in ('draft','sent','accepted','rejected','expired','cancelled')),
  material_cost numeric(10,2) not null default 0,
  transport_cost numeric(10,2) not null default 0,
  staff_cost numeric(10,2) not null default 0,
  external_rental_cost numeric(10,2) not null default 0,
  maintenance_cost numeric(10,2) not null default 0,
  extra_cost numeric(10,2) not null default 0,
  total_cost numeric(10,2) generated always as (material_cost + transport_cost + staff_cost + external_rental_cost + maintenance_cost + extra_cost) stored,
  target_margin numeric(5,4) not null default 0.5000 check (target_margin > 0 and target_margin < 1),
  minimum_price numeric(10,2) generated always as (round((material_cost + transport_cost + staff_cost + external_rental_cost + maintenance_cost + extra_cost) / (1 - target_margin), 2)) stored,
  suggested_price numeric(10,2),
  final_price numeric(10,2),
  expected_profit numeric(10,2) generated always as (coalesce(final_price, suggested_price, 0) - (material_cost + transport_cost + staff_cost + external_rental_cost + maintenance_cost + extra_cost)) stored,
  margin_percent numeric(7,4) generated always as (
    case
      when coalesce(final_price, suggested_price, 0) <= 0 then 0
      else round(((coalesce(final_price, suggested_price, 0) - (material_cost + transport_cost + staff_cost + external_rental_cost + maintenance_cost + extra_cost)) / coalesce(final_price, suggested_price, 0)), 4)
    end
  ) stored,
  profitability_status text generated always as (
    case
      when coalesce(final_price, suggested_price, 0) <= 0 then 'sin_precio'
      when ((coalesce(final_price, suggested_price, 0) - (material_cost + transport_cost + staff_cost + external_rental_cost + maintenance_cost + extra_cost)) / coalesce(final_price, suggested_price, 0)) >= target_margin then 'verde'
      when ((coalesce(final_price, suggested_price, 0) - (material_cost + transport_cost + staff_cost + external_rental_cost + maintenance_cost + extra_cost)) / coalesce(final_price, suggested_price, 0)) >= 0.35 then 'amarillo'
      else 'rojo'
    end
  ) stored,
  customer_message text,
  internal_notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.quote_cost_items (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.quotes(id) on delete cascade,
  cost_category text not null check (cost_category in ('materials','transport','staff','external_rental','maintenance','extra')),
  description text not null,
  quantity numeric(10,2) not null default 1 check (quantity > 0),
  unit_cost numeric(10,2) not null default 0 check (unit_cost >= 0),
  line_total numeric(10,2) generated always as (quantity * unit_cost) stored,
  notes text,
  created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Transport and routing
-- -----------------------------------------------------------------------------
create table if not exists public.business_locations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address_text text,
  latitude numeric(10,7),
  longitude numeric(10,7),
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((latitude is null and longitude is null) or (latitude between -90 and 90 and longitude between -180 and 180))
);

create unique index if not exists business_locations_one_default
on public.business_locations ((is_default))
where is_default and is_active;

create table if not exists public.event_locations (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id) on delete cascade,
  address_text text not null,
  google_place_id text,
  latitude numeric(10,7),
  longitude numeric(10,7),
  zone_name text,
  access_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((latitude is null and longitude is null) or (latitude between -90 and 90 and longitude between -180 and 180))
);

create table if not exists public.transport_rate_profiles (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  base_fee numeric(10,2) not null default 20,
  cost_per_km_roundtrip numeric(10,2) not null default 3,
  cost_per_minute numeric(10,2) not null default 0,
  light_load_surcharge numeric(10,2) not null default 0,
  medium_load_surcharge numeric(10,2) not null default 20,
  heavy_load_surcharge numeric(10,2) not null default 45,
  safety_margin numeric(10,2) not null default 15,
  rounding_step numeric(10,2) not null default 10,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists transport_rate_profiles_one_default
on public.transport_rate_profiles ((is_default))
where is_default and is_active;

create table if not exists public.transport_estimates (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id) on delete set null,
  quote_id uuid references public.quotes(id) on delete set null,
  origin_business_location_id uuid references public.business_locations(id) on delete set null,
  destination_event_location_id uuid references public.event_locations(id) on delete set null,
  load_type text not null default 'medium' check (load_type in ('light','medium','heavy')),
  distance_km_one_way numeric(10,2) not null default 0,
  duration_minutes_one_way numeric(10,2) not null default 0,
  suggested_cost numeric(10,2) not null default 0,
  final_cost numeric(10,2),
  provider text,
  provider_payload jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.vehicles (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  plate text,
  capacity_notes text,
  cost_per_km numeric(10,2),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.daily_routes (
  id uuid primary key default gen_random_uuid(),
  route_date date not null,
  vehicle_id uuid references public.vehicles(id) on delete set null,
  route_status text not null default 'draft' check (route_status in ('draft','planned','in_progress','completed','cancelled')),
  total_distance_km numeric(10,2) not null default 0,
  total_duration_minutes numeric(10,2) not null default 0,
  total_transport_cost numeric(10,2) not null default 0,
  risk_status text not null default 'pending' check (risk_status in ('pending','verde','amarillo','rojo')),
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.daily_route_stops (
  id uuid primary key default gen_random_uuid(),
  daily_route_id uuid not null references public.daily_routes(id) on delete cascade,
  order_id uuid references public.orders(id) on delete set null,
  event_location_id uuid references public.event_locations(id) on delete set null,
  stop_order integer not null,
  stop_type text not null default 'setup' check (stop_type in ('pickup','setup','teardown','delivery','return_base')),
  planned_arrival_at timestamptz,
  planned_departure_at timestamptz,
  service_duration_minutes integer not null default 60,
  travel_from_previous_minutes numeric(10,2) not null default 0,
  distance_from_previous_km numeric(10,2) not null default 0,
  risk_status text not null default 'pending' check (risk_status in ('pending','verde','amarillo','rojo')),
  notes text,
  created_at timestamptz not null default now(),
  unique (daily_route_id, stop_order)
);

-- -----------------------------------------------------------------------------
-- Inventory: availability, colors and reservations
-- -----------------------------------------------------------------------------
create table if not exists public.inventory_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.inventory_categories(id) on delete set null,
  code text not null unique,
  name text not null,
  current_color text,
  current_status text not null default 'available' check (current_status in ('available','reserved','in_use','maintenance','requires_paint','damaged','lost','external_rental','out_of_service')),
  current_location text not null default 'base',
  condition_notes text,
  replacement_value numeric(10,2),
  image_url text,
  is_active boolean not null default true,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.inventory_status_history (
  id uuid primary key default gen_random_uuid(),
  inventory_item_id uuid not null references public.inventory_items(id) on delete cascade,
  previous_status text,
  new_status text,
  previous_color text,
  new_color text,
  previous_location text,
  new_location text,
  condition_notes text,
  photo_url text,
  source_type text not null default 'manual' check (source_type in ('manual','quote','order_return','maintenance','ai_suggestion')),
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.inventory_reservations (
  id uuid primary key default gen_random_uuid(),
  inventory_item_id uuid not null references public.inventory_items(id) on delete cascade,
  order_id uuid references public.orders(id) on delete cascade,
  quote_id uuid references public.quotes(id) on delete set null,
  reserved_from timestamptz not null,
  reserved_until timestamptz not null,
  required_color text,
  status text not null default 'reserved' check (status in ('draft','reserved','in_use','returned','cancelled')),
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check (reserved_until > reserved_from)
);

do $$
begin
  alter table public.inventory_reservations
    add constraint inventory_reservations_no_overlap
    exclude using gist (
      inventory_item_id with =,
      tstzrange(reserved_from, reserved_until, '[)') with &&
    )
    where (status in ('reserved', 'in_use'));
exception
  when duplicate_object then null;
end $$;

create table if not exists public.event_inventory_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id) on delete cascade,
  quote_id uuid references public.quotes(id) on delete set null,
  inventory_item_id uuid references public.inventory_items(id) on delete set null,
  required_color text,
  actual_color text,
  requires_paint boolean not null default false,
  paint_cost numeric(10,2) not null default 0,
  external_rental_cost numeric(10,2) not null default 0,
  notes text,
  created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- AI outputs: never store API keys here, only results and audit data.
-- -----------------------------------------------------------------------------
create table if not exists public.ai_quote_outputs (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id) on delete cascade,
  quote_id uuid references public.quotes(id) on delete cascade,
  prompt_context jsonb not null default '{}'::jsonb,
  ai_result jsonb not null default '{}'::jsonb,
  model text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Updated-at triggers
-- -----------------------------------------------------------------------------
drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists set_clients_updated_at on public.clients;
create trigger set_clients_updated_at before update on public.clients
for each row execute function public.set_updated_at();

drop trigger if exists set_quote_templates_updated_at on public.quote_templates;
create trigger set_quote_templates_updated_at before update on public.quote_templates
for each row execute function public.set_updated_at();

drop trigger if exists set_quotes_updated_at on public.quotes;
create trigger set_quotes_updated_at before update on public.quotes
for each row execute function public.set_updated_at();

drop trigger if exists set_business_locations_updated_at on public.business_locations;
create trigger set_business_locations_updated_at before update on public.business_locations
for each row execute function public.set_updated_at();

drop trigger if exists set_event_locations_updated_at on public.event_locations;
create trigger set_event_locations_updated_at before update on public.event_locations
for each row execute function public.set_updated_at();

drop trigger if exists set_transport_rate_profiles_updated_at on public.transport_rate_profiles;
create trigger set_transport_rate_profiles_updated_at before update on public.transport_rate_profiles
for each row execute function public.set_updated_at();

drop trigger if exists set_daily_routes_updated_at on public.daily_routes;
create trigger set_daily_routes_updated_at before update on public.daily_routes
for each row execute function public.set_updated_at();

drop trigger if exists set_inventory_items_updated_at on public.inventory_items;
create trigger set_inventory_items_updated_at before update on public.inventory_items
for each row execute function public.set_updated_at();

-- -----------------------------------------------------------------------------
-- RLS for new tables
-- -----------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.clients enable row level security;
alter table public.quote_templates enable row level security;
alter table public.quotes enable row level security;
alter table public.quote_cost_items enable row level security;
alter table public.business_locations enable row level security;
alter table public.event_locations enable row level security;
alter table public.transport_rate_profiles enable row level security;
alter table public.transport_estimates enable row level security;
alter table public.vehicles enable row level security;
alter table public.daily_routes enable row level security;
alter table public.daily_route_stops enable row level security;
alter table public.inventory_categories enable row level security;
alter table public.inventory_items enable row level security;
alter table public.inventory_status_history enable row level security;
alter table public.inventory_reservations enable row level security;
alter table public.event_inventory_items enable row level security;
alter table public.ai_quote_outputs enable row level security;

-- Profiles and roles
drop policy if exists "Users read own profile" on public.profiles;
create policy "Users read own profile" on public.profiles
for select to authenticated
using (id = auth.uid() or public.is_admin());

drop policy if exists "Users update own profile" on public.profiles;
create policy "Users update own profile" on public.profiles
for update to authenticated
using (id = auth.uid() or public.is_admin())
with check (id = auth.uid() or public.is_admin());

drop policy if exists "Admins manage user roles" on public.user_roles;
create policy "Admins manage user roles" on public.user_roles
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

-- Broad operational policies by role
drop policy if exists "Staff manage clients" on public.clients;
create policy "Staff manage clients" on public.clients
for all to authenticated
using (public.has_any_role(array['admin','decoradora','ventas']))
with check (public.has_any_role(array['admin','decoradora','ventas']));

drop policy if exists "Staff manage quote templates" on public.quote_templates;
create policy "Staff manage quote templates" on public.quote_templates
for all to authenticated
using (public.has_any_role(array['admin','decoradora','ventas']))
with check (public.has_any_role(array['admin','decoradora','ventas']));

drop policy if exists "Staff manage quotes" on public.quotes;
create policy "Staff manage quotes" on public.quotes
for all to authenticated
using (public.has_any_role(array['admin','decoradora','ventas']))
with check (public.has_any_role(array['admin','decoradora','ventas']));

drop policy if exists "Staff manage quote cost items" on public.quote_cost_items;
create policy "Staff manage quote cost items" on public.quote_cost_items
for all to authenticated
using (public.has_any_role(array['admin','decoradora','ventas']))
with check (public.has_any_role(array['admin','decoradora','ventas']));

drop policy if exists "Staff manage locations" on public.business_locations;
create policy "Staff manage locations" on public.business_locations
for all to authenticated
using (public.has_any_role(array['admin','decoradora','logistica']))
with check (public.has_any_role(array['admin','decoradora','logistica']));

drop policy if exists "Staff manage event locations" on public.event_locations;
create policy "Staff manage event locations" on public.event_locations
for all to authenticated
using (public.has_any_role(array['admin','decoradora','ventas','logistica']))
with check (public.has_any_role(array['admin','decoradora','ventas','logistica']));

drop policy if exists "Staff manage transport rates" on public.transport_rate_profiles;
create policy "Staff manage transport rates" on public.transport_rate_profiles
for all to authenticated
using (public.has_any_role(array['admin','decoradora','logistica']))
with check (public.has_any_role(array['admin','decoradora','logistica']));

drop policy if exists "Staff manage transport estimates" on public.transport_estimates;
create policy "Staff manage transport estimates" on public.transport_estimates
for all to authenticated
using (public.has_any_role(array['admin','decoradora','ventas','logistica']))
with check (public.has_any_role(array['admin','decoradora','ventas','logistica']));

drop policy if exists "Staff manage vehicles" on public.vehicles;
create policy "Staff manage vehicles" on public.vehicles
for all to authenticated
using (public.has_any_role(array['admin','decoradora','logistica']))
with check (public.has_any_role(array['admin','decoradora','logistica']));

drop policy if exists "Staff manage daily routes" on public.daily_routes;
create policy "Staff manage daily routes" on public.daily_routes
for all to authenticated
using (public.has_any_role(array['admin','decoradora','logistica']))
with check (public.has_any_role(array['admin','decoradora','logistica']));

drop policy if exists "Staff manage daily route stops" on public.daily_route_stops;
create policy "Staff manage daily route stops" on public.daily_route_stops
for all to authenticated
using (public.has_any_role(array['admin','decoradora','logistica']))
with check (public.has_any_role(array['admin','decoradora','logistica']));

drop policy if exists "Inventory staff manage categories" on public.inventory_categories;
create policy "Inventory staff manage categories" on public.inventory_categories
for all to authenticated
using (public.has_any_role(array['admin','decoradora','inventario']))
with check (public.has_any_role(array['admin','decoradora','inventario']));

drop policy if exists "Inventory staff manage items" on public.inventory_items;
create policy "Inventory staff manage items" on public.inventory_items
for all to authenticated
using (public.has_any_role(array['admin','decoradora','inventario','logistica']))
with check (public.has_any_role(array['admin','decoradora','inventario','logistica']));

drop policy if exists "Inventory staff manage item history" on public.inventory_status_history;
create policy "Inventory staff manage item history" on public.inventory_status_history
for all to authenticated
using (public.has_any_role(array['admin','decoradora','inventario','logistica']))
with check (public.has_any_role(array['admin','decoradora','inventario','logistica']));

drop policy if exists "Staff manage inventory reservations" on public.inventory_reservations;
create policy "Staff manage inventory reservations" on public.inventory_reservations
for all to authenticated
using (public.has_any_role(array['admin','decoradora','inventario','logistica','ventas']))
with check (public.has_any_role(array['admin','decoradora','inventario','logistica','ventas']));

drop policy if exists "Staff manage event inventory" on public.event_inventory_items;
create policy "Staff manage event inventory" on public.event_inventory_items
for all to authenticated
using (public.has_any_role(array['admin','decoradora','inventario','ventas']))
with check (public.has_any_role(array['admin','decoradora','inventario','ventas']));

drop policy if exists "Staff read ai outputs" on public.ai_quote_outputs;
create policy "Staff read ai outputs" on public.ai_quote_outputs
for select to authenticated
using (public.has_any_role(array['admin','decoradora','ventas']));

drop policy if exists "Staff create ai outputs" on public.ai_quote_outputs;
create policy "Staff create ai outputs" on public.ai_quote_outputs
for insert to authenticated
with check (public.has_any_role(array['admin','decoradora','ventas']));

-- -----------------------------------------------------------------------------
-- Seed safe defaults
-- -----------------------------------------------------------------------------
insert into public.transport_rate_profiles (
  name, base_fee, cost_per_km_roundtrip, cost_per_minute,
  light_load_surcharge, medium_load_surcharge, heavy_load_surcharge,
  safety_margin, rounding_step, is_default, is_active
)
select 'Tarifa base Hello Balloons', 20, 3, 0, 0, 20, 45, 15, 10, true, true
where not exists (select 1 from public.transport_rate_profiles where is_default = true and is_active = true);

insert into public.business_locations (name, address_text, is_default, is_active)
select 'Base Hello Balloons', 'Configurar direccion, latitud y longitud reales', true, true
where not exists (select 1 from public.business_locations where is_default = true and is_active = true);

insert into public.inventory_categories (name, description)
values
  ('Paneles', 'Paneles, fondos y backdrops reutilizables'),
  ('Mesas y cilindros', 'Mesas decorativas, cilindros y bases'),
  ('Estructuras', 'Arcos, soportes y estructuras de montaje'),
  ('Accesorios', 'Elementos decorativos, luces y complementos')
on conflict (name) do nothing;

insert into public.quote_templates (
  name, event_type, package_level, default_setup_minutes, default_teardown_minutes,
  default_staff_count, default_load_type, base_material_cost, base_staff_cost, base_extra_cost
)
select * from (
  values
    ('Decoracion basica', 'General', 'basic', 90, 45, 1, 'light', 180::numeric, 80::numeric, 25::numeric),
    ('Decoracion media', 'General', 'medium', 150, 60, 2, 'medium', 350::numeric, 160::numeric, 50::numeric),
    ('Decoracion premium', 'General', 'premium', 240, 90, 3, 'heavy', 650::numeric, 300::numeric, 100::numeric)
) as seed(name, event_type, package_level, default_setup_minutes, default_teardown_minutes, default_staff_count, default_load_type, base_material_cost, base_staff_cost, base_extra_cost)
where not exists (
  select 1 from public.quote_templates qt where lower(qt.name) = lower(seed.name)
);

-- Helpful indexes
create index if not exists orders_event_date_idx on public.orders(event_date);
create index if not exists orders_status_idx on public.orders(status);
create index if not exists quotes_order_id_idx on public.quotes(order_id);
create index if not exists quotes_status_idx on public.quotes(status);
create index if not exists event_locations_order_id_idx on public.event_locations(order_id);
create index if not exists inventory_items_status_idx on public.inventory_items(current_status);
create index if not exists inventory_reservations_item_date_idx on public.inventory_reservations(inventory_item_id, reserved_from, reserved_until);
create index if not exists daily_routes_date_idx on public.daily_routes(route_date);
