-- Supabase SQL schema for storing unit receipt scan data
-- Jalankan file ini di Supabase SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.vehicle_received_scans (
  id uuid primary key default gen_random_uuid(),

  -- business data hasil scan
  purchase_order text not null,
  vendor_id text not null,
  operator_id text not null,
  product_id text not null,
  vin_number varchar(17) not null,
  condition_notes text not null default 'Good - No Scratch',
  landed_cost_actual numeric(14,2) not null check (landed_cost_actual >= 0),

  -- metadata event / source
  event_type text not null default 'com.arista.inventory.goods_received.verified',
  source text not null default 'arista:branch:jkt-pusat',
  correlation_id text,
  idempotency_key text,

  -- observability payload mentah
  raw_scan text,
  payload jsonb,

  -- lifecycle proses (simpan dulu, publish event di belakang layar)
  submit_status text not null default 'saved' check (submit_status in ('saved','failed')),
  publish_status text not null default 'pending' check (publish_status in ('pending','published','dead-lettered')),
  publish_attempts integer not null default 0 check (publish_attempts >= 0),
  publish_last_error text,
  published_at timestamptz,

  -- waktu operasional
  scanned_at timestamptz not null default now(),
  received_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- opsional untuk ownership user Supabase Auth
  created_by uuid references auth.users(id) on delete set null,

  constraint vehicle_received_scans_vin_length_chk check (char_length(vin_number) = 17)
);

-- idempotency key harus unik jika diisi
create unique index if not exists uq_vehicle_received_scans_idempotency_key
  on public.vehicle_received_scans (idempotency_key)
  where idempotency_key is not null;

create index if not exists idx_vehicle_received_scans_vin_number
  on public.vehicle_received_scans (vin_number);

create index if not exists idx_vehicle_received_scans_purchase_order
  on public.vehicle_received_scans (purchase_order);

create index if not exists idx_vehicle_received_scans_operator_id
  on public.vehicle_received_scans (operator_id);

create index if not exists idx_vehicle_received_scans_publish_status
  on public.vehicle_received_scans (publish_status, created_at desc);

create index if not exists idx_vehicle_received_scans_created_at
  on public.vehicle_received_scans (created_at desc);

create index if not exists idx_vehicle_received_scans_payload_gin
  on public.vehicle_received_scans using gin (payload);

create or replace function public.set_updated_at_vehicle_received_scans()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_set_updated_at_vehicle_received_scans on public.vehicle_received_scans;
create trigger trg_set_updated_at_vehicle_received_scans
before update on public.vehicle_received_scans
for each row
execute function public.set_updated_at_vehicle_received_scans();

-- RLS (aktifkan jika aplikasi mengakses langsung Supabase)
alter table public.vehicle_received_scans enable row level security;

-- baca data milik sendiri
drop policy if exists "vehicle_received_scans_select_own" on public.vehicle_received_scans;
create policy "vehicle_received_scans_select_own"
on public.vehicle_received_scans
for select
to authenticated
using (created_by = auth.uid());

-- insert data milik sendiri
drop policy if exists "vehicle_received_scans_insert_own" on public.vehicle_received_scans;
create policy "vehicle_received_scans_insert_own"
on public.vehicle_received_scans
for insert
to authenticated
with check (created_by = auth.uid());

-- update terbatas untuk record milik sendiri (mis. status publish)
drop policy if exists "vehicle_received_scans_update_own" on public.vehicle_received_scans;
create policy "vehicle_received_scans_update_own"
on public.vehicle_received_scans
for update
to authenticated
using (created_by = auth.uid())
with check (created_by = auth.uid());
