-- Order reference photos uploaded from the public quotation flow.
-- Bucket is private. Staff can read. Public visitors can only upload/insert references.

create extension if not exists pgcrypto;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'order-references',
  'order-references',
  false,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.order_reference_photos (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  storage_bucket text not null default 'order-references',
  storage_path text not null,
  original_filename text,
  mime_type text,
  file_size_bytes integer,
  created_at timestamptz not null default now(),
  unique (storage_bucket, storage_path)
);

alter table public.order_reference_photos enable row level security;

-- Public visitors can attach reference photos only after a request is created.
drop policy if exists "Public insert order references" on public.order_reference_photos;
create policy "Public insert order references"
on public.order_reference_photos
for insert
to anon, authenticated
with check (storage_bucket = 'order-references');

-- Internal staff can read and manage references.
drop policy if exists "Staff manage order references" on public.order_reference_photos;
create policy "Staff manage order references"
on public.order_reference_photos
for all
to authenticated
using (public.has_any_role(array['admin','decoradora','ventas']))
with check (public.has_any_role(array['admin','decoradora','ventas']));

-- Allow public uploads into the private order-references bucket.
drop policy if exists "Public upload order reference photos" on storage.objects;
create policy "Public upload order reference photos"
on storage.objects
for insert
to anon, authenticated
with check (bucket_id = 'order-references');

-- Only internal staff can read uploaded reference photos.
drop policy if exists "Staff read order reference photos" on storage.objects;
create policy "Staff read order reference photos"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'order-references'
  and public.has_any_role(array['admin','decoradora','ventas'])
);

-- Internal staff can remove inappropriate or duplicate references.
drop policy if exists "Staff delete order reference photos" on storage.objects;
create policy "Staff delete order reference photos"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'order-references'
  and public.has_any_role(array['admin','decoradora'])
);

create index if not exists order_reference_photos_order_idx on public.order_reference_photos(order_id);
