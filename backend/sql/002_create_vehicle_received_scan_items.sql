-- Detail table for per-item publish tracking (hybrid batch model)

create table if not exists public.vehicle_received_scan_items (
  id uuid primary key default gen_random_uuid(),
  scan_id uuid not null references public.vehicle_received_scans(id) on delete cascade,

  vin varchar(17) not null,
  model text not null,
  odometer integer not null check (odometer >= 0),
  condition_score text not null,
  received_at timestamptz not null,

  item_status text not null default 'pending'
    check (item_status in ('pending','processing','published','failed')),
  publish_attempts integer not null default 0 check (publish_attempts >= 0),
  publish_error text,
  redpanda_event_id text,
  redpanda_partition integer,
  redpanda_offset bigint,
  published_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint vehicle_received_scan_items_vin_length_chk check (char_length(vin) = 17),
  constraint vehicle_received_scan_items_unique_scan_vin unique (scan_id, vin)
);

create index if not exists idx_vehicle_received_scan_items_scan_id
  on public.vehicle_received_scan_items (scan_id);

create index if not exists idx_vehicle_received_scan_items_status
  on public.vehicle_received_scan_items (item_status, created_at desc);

create or replace function public.set_updated_at_vehicle_received_scan_items()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_set_updated_at_vehicle_received_scan_items on public.vehicle_received_scan_items;
create trigger trg_set_updated_at_vehicle_received_scan_items
before update on public.vehicle_received_scan_items
for each row
execute function public.set_updated_at_vehicle_received_scan_items();

alter table public.vehicle_received_scan_items enable row level security;

drop policy if exists "vehicle_received_scan_items_select_own" on public.vehicle_received_scan_items;
create policy "vehicle_received_scan_items_select_own"
on public.vehicle_received_scan_items
for select
to authenticated
using (
  exists (
    select 1
    from public.vehicle_received_scans s
    where s.id = scan_id and s.created_by = auth.uid()
  )
);

drop policy if exists "vehicle_received_scan_items_insert_own" on public.vehicle_received_scan_items;
create policy "vehicle_received_scan_items_insert_own"
on public.vehicle_received_scan_items
for insert
to authenticated
with check (
  exists (
    select 1
    from public.vehicle_received_scans s
    where s.id = scan_id and s.created_by = auth.uid()
  )
);

drop policy if exists "vehicle_received_scan_items_update_own" on public.vehicle_received_scan_items;
create policy "vehicle_received_scan_items_update_own"
on public.vehicle_received_scan_items
for update
to authenticated
using (
  exists (
    select 1
    from public.vehicle_received_scans s
    where s.id = scan_id and s.created_by = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.vehicle_received_scans s
    where s.id = scan_id and s.created_by = auth.uid()
  )
);
