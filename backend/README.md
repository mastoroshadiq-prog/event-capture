# Backend Gateway (FastAPI)

Kontrak awal (fase 1):

- `POST /v1/events/vehicle-received`
- `POST /v1/events/vehicle-inspected`

Endpoint menerima payload ingest domain gudang (5W1H), memvalidasi schema, lalu membentuk CloudEvents v1.0 dan mengembalikan ACK `202 Accepted`.

## Jalankan lokal

```bash
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

OpenAPI: `http://127.0.0.1:8000/docs`

## Environment Variable (Auth - Generic, recommended: Supabase)

Set minimal env berikut sebelum menjalankan API:

- `AUTH_ISSUER`
- `AUTH_AUDIENCE` (boleh dikosongkan jika `AUTH_VERIFY_AUDIENCE=false`)

Opsional (punya default):

- `AUTH_JWKS_URL` (default: `<AUTH_ISSUER>/.well-known/jwks.json`)
- `AUTH_JWT_ALGORITHMS` (default: `RS256`)
- `AUTH_VERIFY_AUDIENCE` (default: `true`)
- `AUTH_REQUIRED_SCOPE` (default: `events:ingest`, kosongkan untuk non-strict)
- `AUTH_REQUIRED_ROLE` (default: `warehouse_operator`, kosongkan untuk non-strict)
- `AUTH_SUPERVISOR_ROLE` (default: `warehouse_supervisor`)
- `AUTH_OPERATOR_ID_CLAIM` (default: `https://event-capture/operator_id`)
- `AUTH_DEVICE_ID_CLAIM` (default: `https://event-capture/device_id`, boleh kosong)
- `AUTH_ENFORCE_OPERATOR_MATCH` (default: `true`)
- `AUTH_ENFORCE_DEVICE_MATCH` (default: `true`)
- `AUTH_ALLOWED_DEVICE_IDS` (CSV, mis. `device-a,device-b`)

Backward compatibility masih didukung:

- `AUTH0_DOMAIN`, `AUTH0_ISSUER`, `AUTH0_AUDIENCE`

Header penting saat ingest:

- `Authorization: Bearer <jwt>`
- `X-Idempotency-Key: <unik-per-payload>` (opsional tapi direkomendasikan)
- `X-Correlation-Id: <trace-id>` (opsional)

## Environment Variable (Redpanda & Resilience)

Wajib untuk publish ke Redpanda:

- `REDPANDA_BOOTSTRAP_SERVERS`
- `REDPANDA_TOPIC`

Opsional untuk security:

- `REDPANDA_SECURITY_PROTOCOL` (default: `PLAINTEXT`, contoh `SASL_SSL`)
- `REDPANDA_SASL_MECHANISM` (contoh `SCRAM-SHA-256`)
- `REDPANDA_SASL_USERNAME`
- `REDPANDA_SASL_PASSWORD`
- `REDPANDA_CLIENT_ID` (default: `event-capture-gateway`)
- `REDPANDA_ACKS` (default: `all`)

Opsional (punya default):

- `PUBLISH_MAX_RETRIES` (default: `3`)
- `PUBLISH_TIMEOUT_SECONDS` (default: `5.0`)
- `CIRCUIT_BREAKER_FAILURE_THRESHOLD` (default: `5`)
- `CIRCUIT_BREAKER_RESET_SECONDS` (default: `30`)
- `DEAD_LETTER_DIR` (default: `backend/dead_letter`)

Catatan alur publish:

- Jika publish sukses -> response `publish_status=published`.
- Jika publish gagal/circuit open -> event ditulis ke dead-letter file dan response `publish_status=dead-lettered` + `dead_letter_id`.

Contoh quick config dev:

```bash
set REDPANDA_BOOTSTRAP_SERVERS=localhost:9092
set REDPANDA_TOPIC=vehicle-events
set REDPANDA_SECURITY_PROTOCOL=PLAINTEXT
```

## Konfigurasi siap pakai (Redpanda + Supabase)

Template environment yang sudah disesuaikan tersedia di `backend/.env.redpanda`.

Nilai yang sudah diisikan:

- `REDPANDA_BOOTSTRAP_SERVERS=d6gk58emqido6iapffn0.any.us-east-1.mpx.prd.cloud.redpanda.com:9092`
- `REDPANDA_TOPIC=penerimaan_unit`
- template `AUTH_ISSUER`, `AUTH_JWKS_URL`, `AUTH_AUDIENCE` untuk Supabase

Yang perlu Anda isi manual:

- `AUTH_ISSUER` (pakai project ref Supabase Anda)
- `AUTH_JWKS_URL` (otomatis jika issuer benar, tapi tetap disediakan)
- `REDPANDA_SASL_USERNAME`
- `REDPANDA_SASL_PASSWORD`

Contoh Supabase:

```bash
set AUTH_ISSUER=https://<project-ref>.supabase.co/auth/v1
set AUTH_JWKS_URL=https://<project-ref>.supabase.co/auth/v1/.well-known/jwks.json
set AUTH_AUDIENCE=authenticated
set AUTH_REQUIRED_SCOPE=
set AUTH_REQUIRED_ROLE=
set AUTH_OPERATOR_ID_CLAIM=sub
set AUTH_ENFORCE_OPERATOR_MATCH=false
set AUTH_ENFORCE_DEVICE_MATCH=false
```
