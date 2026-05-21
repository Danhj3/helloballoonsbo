-- Hello Balloons event memory module
-- Stores completed event photos, materials, furniture and operational learnings.

create extension if not exists pgcrypto;

-- Private bucket for event photos. Access is controlled with storage RLS.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'event-photos',
  'event-photos',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.event_memories (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id) on delete set null,
  quote_id uuid references public.quotes(id) on delete set null,
  title text not null,
  event_type text,
  event_date date,
  client_name text,
  theme text,
  color_palette text[] not null default '{}',
  package_level text check (package_level in ('basic','medium','premium','custom')),
  location_summary text,
  final_price numeric(10,2),
  real_total_cost numeric(10,2),
  real_profit numeric(10,2) generated always as (coalesce(final_price, 0) - coalesce(real_total_cost, 0)) stored,
  real_margin_percent numeric(7,4) generated always as (
    case
      when coalesce(final_price, 0) <= 0 then 0
      else round((coalesce(final_price, 0) - coalesce(real_total_cost, 0)) / coalesce(final_price, 0), 4)
    end
  ) stored,
  what_worked text,
  what_to_improve text,
  client_feedback text,
  internal_notes text,
  ai_summary jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.event_memory_items (
  id uuid primary key default gen_random_uuid(),
  event_memory_id uuid not null references public.event_memories(id) on delete cascade,
  inventory_item_id uuid references public.inventory_items(id) on delete set null,
  item_name text not null,
  item_code text,
  item_type text not null default 'other' check (item_type in ('panel','mesa','cilindro','estructura','globos','tela','luz','accesorio','material','alquiler','otro','other')),
  source text not null default 'owned' check (source in ('owned','external_rental','purchased','borrowed','other')),
  quantity numeric(10,2) not null default 1 check (quantity > 0),
  color_used text,
  color_before text,
  color_after text,
  condition_after text,
  unit_cost numeric(10,2) not null default 0,
  line_cost numeric(10,2) generated always as (quantity * unit_cost) stored,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.event_memory_photos (
  id uuid primary key default gen_random_uuid(),
  event_memory_id uuid not null references public.event_memories(id) on delete cascade,
  storage_bucket text not null default 'event-photos',
  storage_path text not null,
  original_filename text,
  mime_type text,
  file_size_bytes integer,
  caption text,
  tags text[] not null default '{}',
  is_cover boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (storage_bucket, storage_path)
);

create table if not exists public.event_learning_notes (
  id uuid primary key default gen_random_uuid(),
  event_memory_id uuid not null references public.event_memories(id) on delete cascade,
  learning_type text not null check (learning_type in ('pricing','inventory','transport','staff','design','client','risk','other')),
  note text not null,
  should_reuse boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Updated-at trigger
create trigger set_event_memories_updated_at
before update on public.event_memories
for each row execute function public.set_updated_at();

alter table public.event_memories enable row level security;
alter table public.event_memory_items enable row level security;
alter table public.event_memory_photos enable row level security;
alter table public.event_learning_notes enable row level security;

-- Event memories are internal operational knowledge.
drop policy if exists "Staff manage event memories" on public.event_memories;
create policy "Staff manage event memories"
on public.event_memories
for all
to authenticated
using (public.has_any_role(array['admin','decoradora','ventas','inventario','logistica']))
with check (public.has_any_role(array['admin','decoradora','ventas','inventario','logistica']));

drop policy if exists "Staff manage event memory items" on public.event_memory_items;
create policy "Staff manage event memory items"
on public.event_memory_items
for all
to authenticated
using (public.has_any_role(array['admin','decoradora','ventas','inventario','logistica']))
with check (public.has_any_role(array['admin','decoradora','ventas','inventario','logistica']));

drop policy if exists "Staff manage event memory photos" on public.event_memory_photos;
create policy "Staff manage event memory photos"
on public.event_memory_photos
for all
to authenticated
using (public.has_any_role(array['admin','decoradora','ventas','inventario','logistica']))
with check (public.has_any_role(array['admin','decoradora','ventas','inventario','logistica']));

drop policy if exists "Staff manage event learning notes" on public.event_learning_notes;
create policy "Staff manage event learning notes"
on public.event_learning_notes
for all
to authenticated
using (public.has_any_role(array['admin','decoradora','ventas','inventario','logistica']))
with check (public.has_any_role(array['admin','decoradora','ventas','inventario','logistica']));

-- Storage RLS for event photos bucket.
drop policy if exists "Staff read event photos" on storage.objects;
create policy "Staff read event photos"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'event-photos'
  and public.has_any_role(array['admin','decoradora','ventas','inventario','logistica'])
);

drop policy if exists "Staff upload event photos" on storage.objects;
create policy "Staff upload event photos"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'event-photos'
  and public.has_any_role(array['admin','decoradora','ventas','inventario','logistica'])
);

drop policy if exists "Staff update event photos" on storage.objects;
create policy "Staff update event photos"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'event-photos'
  and public.has_any_role(array['admin','decoradora','ventas','inventario','logistica'])
)
with check (
  bucket_id = 'event-photos'
  and public.has_any_role(array['admin','decoradora','ventas','inventario','logistica'])
);

drop policy if exists "Admins delete event photos" on storage.objects;
create policy "Admins delete event photos"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'event-photos'
  and public.has_any_role(array['admin','decoradora'])
);

create index if not exists event_memories_event_date_idx on public.event_memories(event_date);
create index if not exists event_memories_event_type_idx on public.event_memories(event_type);
create index if not exists event_memory_items_memory_idx on public.event_memory_items(event_memory_id);
create index if not exists event_memory_photos_memory_idx on public.event_memory_photos(event_memory_id);
create index if not exists event_learning_notes_memory_idx on public.event_learning_notes(event_memory_id);
