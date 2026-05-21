-- Store the original Google Maps link shared by the client.
alter table public.event_locations
add column if not exists maps_url text;

create index if not exists event_locations_maps_url_idx
on public.event_locations using btree (maps_url);
