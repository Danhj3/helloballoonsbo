-- Public event gallery support for Hello Balloons landing page.
-- Keeps internal event memories private unless explicitly marked public.

alter table public.event_memories
add column if not exists is_public boolean not null default false;

alter table public.event_memories
add column if not exists public_title text;

alter table public.event_memory_photos
add column if not exists is_public boolean not null default false;

alter table public.event_memory_photos
add column if not exists display_order integer not null default 0;

-- Public bucket only for photos intentionally selected for the landing page.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'event-gallery',
  'event-gallery',
  true,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Public visitors can read only memories explicitly approved for landing.
drop policy if exists "Public read approved event memories" on public.event_memories;
create policy "Public read approved event memories"
on public.event_memories
for select
to anon, authenticated
using (is_public = true);

-- Public visitors can read only photos explicitly approved for landing.
drop policy if exists "Public read approved event memory photos" on public.event_memory_photos;
create policy "Public read approved event memory photos"
on public.event_memory_photos
for select
to anon, authenticated
using (is_public = true and storage_bucket = 'event-gallery');

-- Staff can upload public gallery photos.
drop policy if exists "Staff upload public gallery photos" on storage.objects;
create policy "Staff upload public gallery photos"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'event-gallery'
  and public.has_any_role(array['admin','decoradora','ventas'])
);

-- Public can read objects in the public event-gallery bucket.
drop policy if exists "Public read event gallery storage" on storage.objects;
create policy "Public read event gallery storage"
on storage.objects
for select
to anon, authenticated
using (bucket_id = 'event-gallery');

-- Staff can update public gallery objects.
drop policy if exists "Staff update public gallery photos" on storage.objects;
create policy "Staff update public gallery photos"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'event-gallery'
  and public.has_any_role(array['admin','decoradora','ventas'])
)
with check (
  bucket_id = 'event-gallery'
  and public.has_any_role(array['admin','decoradora','ventas'])
);

-- Admin/decoradora can delete public gallery photos.
drop policy if exists "Staff delete public gallery photos" on storage.objects;
create policy "Staff delete public gallery photos"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'event-gallery'
  and public.has_any_role(array['admin','decoradora'])
);

create index if not exists event_memories_public_idx on public.event_memories(is_public, event_date desc);
create index if not exists event_memory_photos_public_idx on public.event_memory_photos(is_public, display_order);
