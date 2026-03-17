-- Master PO + item reference tables for online PO/VIN validation (v3.0)

create extension if not exists pgcrypto;

create table if not exists public.po_master (
  id uuid primary key default gen_random_uuid(),
  po_number text not null unique,
  vendor_info text not null,
  carrier_name text not null,
  description text not null,
  warehouse_id text not null,
  destination_branch text not null,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.po_master_items (
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references public.po_master(id) on delete cascade,
  vin varchar(17) not null,
  model text not null,
  color text not null,
  status text not null default 'expected' check (status in ('expected','received','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint po_master_items_unique_po_vin unique (po_id, vin),
  constraint po_master_items_vin_length_chk check (char_length(vin) = 17)
);

create index if not exists idx_po_master_po_number on public.po_master (po_number);
create index if not exists idx_po_master_status on public.po_master (status);
create index if not exists idx_po_master_items_po_id on public.po_master_items (po_id);
create index if not exists idx_po_master_items_vin on public.po_master_items (vin);

create or replace function public.set_updated_at_po_master()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_set_updated_at_po_master on public.po_master;
create trigger trg_set_updated_at_po_master
before update on public.po_master
for each row
execute function public.set_updated_at_po_master();

create or replace function public.set_updated_at_po_master_items()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_set_updated_at_po_master_items on public.po_master_items;
create trigger trg_set_updated_at_po_master_items
before update on public.po_master_items
for each row
execute function public.set_updated_at_po_master_items();

-- Seed data synchronized with context/mock-data.md
insert into public.po_master (
  po_number, vendor_info, carrier_name, description, warehouse_id, destination_branch, status
) values
  ('PO-ARISTA-2026-006', 'PT Toyota Astra Motor', 'Sinar Logistic', 'Stock Replenishment - Mixed Models', 'WH-SDR-01', 'ARISTA Sudirman', 'active'),
  ('PO-ARISTA-2026-007', 'PT Astra Daihatsu Motor', 'Internal Drive', 'Customer Order - Pesanan Khusus', 'WH-SDR-02', 'ARISTA Sudirman', 'active'),
  ('PO-ARISTA-2026-008', 'PT Astra Daihatsu Motor', 'Fleet Transport Service', 'Fleet Expansion - Gran Max Series', 'WH-SDR-01', 'ARISTA Sudirman', 'active')
on conflict (po_number) do update set
  vendor_info = excluded.vendor_info,
  carrier_name = excluded.carrier_name,
  description = excluded.description,
  warehouse_id = excluded.warehouse_id,
  destination_branch = excluded.destination_branch,
  status = excluded.status,
  updated_at = now();

insert into public.po_master_items (po_id, vin, model, color, status)
select p.id, d.vin, d.model, d.color, 'expected'
from public.po_master p
join (
  values
    ('PO-ARISTA-2026-006', 'MHRM1F1G1PK200001', 'Innova Zenix V Hybrid', 'Platinum White'),
    ('PO-ARISTA-2026-006', 'MHRM1F1G1PK200002', 'Veloz 1.5 Q CVT', 'Black Metallic'),
    ('PO-ARISTA-2026-006', 'MHRM1F1G1PK200003', 'Avanza 1.5 G CVT', 'Silver Metallic'),
    ('PO-ARISTA-2026-006', 'MHRM1F1G1PK200004', 'Fortuner 2.8 GR Sport', 'Super White'),
    ('PO-ARISTA-2026-007', 'MHRK2F1G1RK300999', 'Daihatsu Terios R AT', 'Greenish Gun Metal'),
    ('PO-ARISTA-2026-008', 'MHRB3F1G1SK400111', 'Gran Max PU 1.5 AC PS', 'White'),
    ('PO-ARISTA-2026-008', 'MHRB3F1G1SK400112', 'Gran Max PU 1.5 AC PS', 'White'),
    ('PO-ARISTA-2026-008', 'MHRB3F1G1SK400113', 'Gran Max PU 1.5 AC PS', 'White')
) as d(po_number, vin, model, color)
  on p.po_number = d.po_number
on conflict (po_id, vin) do update set
  model = excluded.model,
  color = excluded.color,
  status = excluded.status,
  updated_at = now();

