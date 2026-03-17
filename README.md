# Event Capture - Vehicle Receiving Gateway

Project ini adalah implementasi **mobile event capture** untuk proses penerimaan unit kendaraan berbasis QR/Barcode, dengan output **CloudEvents** dan integrasi **Redpanda + Redpanda Connect + Supabase**.

## Ringkasan Arsitektur

Alur utama saat ini:
1. Operator scan QR PO dan QR VIN unit di aplikasi Flutter.
2. App membentuk payload CloudEvent batch lalu kirim ke backend FastAPI.
3. Backend publish event per-item ke topic Redpanda (fan-out).
4. Redpanda Connect memproses stream dan sink ke Supabase.
5. Data siap dikonsumsi sistem downstream (mis. Odoo).

Dokumen desain pipeline tersedia di [`plans/redpanda-connect-poc-design.md`](plans/redpanda-connect-poc-design.md).

## Komponen Utama

- **Mobile App (Flutter)**
  - Entry point: [`lib/main.dart`](lib/main.dart)
  - State scan receiving: [`lib/receiving_state.dart`](lib/receiving_state.dart)
- **Backend API (FastAPI)**
  - App bootstrap: [`backend/app/main.py`](backend/app/main.py)
  - Event routes: [`backend/app/api/routes_events.py`](backend/app/api/routes_events.py)
  - Settings/env: [`backend/app/core/settings.py`](backend/app/core/settings.py)
- **SQL Schema (Supabase/Postgres)**
  - Scan header: [`backend/sql/001_create_vehicle_received_scans.sql`](backend/sql/001_create_vehicle_received_scans.sql)
  - Scan item detail: [`backend/sql/002_create_vehicle_received_scan_items.sql`](backend/sql/002_create_vehicle_received_scan_items.sql)
  - PO master + items (v3.0): [`backend/sql/003_create_po_master_tables.sql`](backend/sql/003_create_po_master_tables.sql)
- **Pipeline Config (Redpanda Connect)**
  - Sink config: [`context/pipeline.yaml`](context/pipeline.yaml)

## Fitur yang Sudah Diimplementasikan

- Scan PO -> verifikasi VIN per-item -> submit batch.
- Payload CloudEvent 5W1H untuk proses receiving.
- Publish Redpanda per-item dengan status granular.
- Event-first mode backend (`EVENT_FIRST_MODE=true`) untuk transisi sink via Redpanda Connect.
- UI modernized (Material 3) + progress per item + popup hasil submit.
- Reset otomatis form scan setelah submit sukses.
- Idempotency key deterministik untuk mengurangi duplikasi saat retry.
- Lookup PO online dari Supabase (menggantikan hardcoded SSOT untuk uji v3.0).

## Menjalankan Project

### 1) Backend FastAPI

```bash
cd backend
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

Dokumentasi API lokal:
- `http://127.0.0.1:8000/docs`

### 2) Flutter App

```bash
flutter pub get
flutter run
```

## Konfigurasi Environment

Contoh env aktif ada di [`backend/.env.redpanda`](backend/.env.redpanda).

Minimal variabel penting:
- `REDPANDA_BOOTSTRAP_SERVERS`
- `REDPANDA_TOPIC`
- `REDPANDA_SECURITY_PROTOCOL`
- `REDPANDA_SASL_MECHANISM`
- `REDPANDA_SASL_USERNAME`
- `REDPANDA_SASL_PASSWORD`
- `SUPABASE_DB_URL`
- `EVENT_FIRST_MODE=true`

## Data Uji dan Mock

- Mock-data v3.0 referensi QR testing kit: [`context/mock-data.md`](context/mock-data.md)
- Disarankan untuk test lanjutan: update data master di Supabase melalui SQL [`backend/sql/003_create_po_master_tables.sql`](backend/sql/003_create_po_master_tables.sql), tanpa rebuild app.

## Catatan Operasional

- Pipeline Redpanda Connect menggunakan pola **at-least-once + idempotent sink (upsert)**.
- Jika terjadi retry/replay event, sink dirancang meminimalkan duplikasi pada kunci unik parent-child.
- Untuk device fisik, pastikan base URL backend menggunakan IP LAN (bukan `127.0.0.1`).

## Status

Project aktif dikembangkan untuk POC receiving ARISTA dengan roadmap integrasi ke ERP/Odoo berbasis event stream.
