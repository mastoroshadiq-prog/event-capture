from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

from psycopg import Error as PsycopgError
from psycopg import connect

from app.core.settings import get_settings
from app.models.cloud_events import GoodsReceivedVerifiedCloudEvent
from app.models.cloud_events import VehicleInventoryReceivedCloudEvent


@dataclass(frozen=True)
class ScanStorageResult:
    record_id: str


@dataclass(frozen=True)
class ScanItemStorageResult:
    item_record_id: str
    vin: str


class ScanStorageError(RuntimeError):
    """Raised when scan data cannot be stored or updated."""


def _get_connection_string() -> str:
    settings = get_settings()
    if not settings.supabase_db_url:
        raise ScanStorageError("SUPABASE_DB_URL (or DATABASE_URL) is not configured")
    return settings.supabase_db_url


def save_goods_received_scan(
    *,
    cloud_event: GoodsReceivedVerifiedCloudEvent,
    correlation_id: str,
    idempotency_key: str | None,
) -> ScanStorageResult:
    conn_str = _get_connection_string()
    try:
        with connect(conn_str) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    insert into public.vehicle_received_scans (
                        purchase_order,
                        vendor_id,
                        operator_id,
                        product_id,
                        vin_number,
                        condition_notes,
                        landed_cost_actual,
                        event_type,
                        source,
                        correlation_id,
                        idempotency_key,
                        payload,
                        submit_status,
                        publish_status,
                        scanned_at,
                        created_at,
                        updated_at
                    ) values (
                        %(purchase_order)s,
                        %(vendor_id)s,
                        %(operator_id)s,
                        %(product_id)s,
                        %(vin_number)s,
                        %(condition_notes)s,
                        %(landed_cost_actual)s,
                        %(event_type)s,
                        %(source)s,
                        %(correlation_id)s,
                        %(idempotency_key)s,
                        %(payload)s::jsonb,
                        'saved',
                        'pending',
                        %(scanned_at)s,
                        now(),
                        now()
                    )
                    on conflict (idempotency_key) where idempotency_key is not null
                    do update set
                        payload = excluded.payload,
                        updated_at = now()
                    returning id::text
                    """,
                    {
                        "purchase_order": cloud_event.subject,
                        "vendor_id": cloud_event.data.vendor_id,
                        "operator_id": cloud_event.data.operator_id,
                        "product_id": cloud_event.data.product_id,
                        "vin_number": cloud_event.data.vin_number,
                        "condition_notes": cloud_event.data.condition_notes,
                        "landed_cost_actual": cloud_event.data.landed_cost_actual,
                        "event_type": cloud_event.type,
                        "source": cloud_event.source,
                        "correlation_id": correlation_id,
                        "idempotency_key": idempotency_key,
                        "payload": cloud_event.model_dump_json(),
                        "scanned_at": cloud_event.time,
                    },
                )
                row = cur.fetchone()
                if row is None:
                    raise ScanStorageError("Failed to persist vehicle_received_scans record")

            conn.commit()
    except PsycopgError as error:
        raise ScanStorageError(f"Supabase DB error: {error}") from error

    return ScanStorageResult(record_id=row[0])


def save_vehicle_inventory_received_scan(
    *,
    cloud_event: VehicleInventoryReceivedCloudEvent,
    correlation_id: str,
    idempotency_key: str | None,
) -> ScanStorageResult:
    conn_str = _get_connection_string()
    try:
        with connect(conn_str) as conn:
            with conn.cursor() as cur:
                first_item = cloud_event.data.received_items[0]
                cur.execute(
                    """
                    insert into public.vehicle_received_scans (
                        purchase_order,
                        vendor_id,
                        operator_id,
                        product_id,
                        vin_number,
                        condition_notes,
                        landed_cost_actual,
                        event_type,
                        source,
                        correlation_id,
                        idempotency_key,
                        payload,
                        submit_status,
                        publish_status,
                        scanned_at,
                        created_at,
                        updated_at
                    ) values (
                        %(purchase_order)s,
                        %(vendor_id)s,
                        %(operator_id)s,
                        %(product_id)s,
                        %(vin_number)s,
                        %(condition_notes)s,
                        %(landed_cost_actual)s,
                        %(event_type)s,
                        %(source)s,
                        %(correlation_id)s,
                        %(idempotency_key)s,
                        %(payload)s::jsonb,
                        'saved',
                        'pending',
                        %(scanned_at)s,
                        now(),
                        now()
                    )
                    on conflict (idempotency_key) where idempotency_key is not null
                    do update set
                        payload = excluded.payload,
                        updated_at = now()
                    returning id::text
                    """,
                    {
                        "purchase_order": cloud_event.subject,
                        "vendor_id": "batch",
                        "operator_id": cloud_event.data.receiving_context.inspector_id,
                        "product_id": first_item.model,
                        "vin_number": first_item.vin,
                        "condition_notes": first_item.condition,
                        "landed_cost_actual": 0,
                        "event_type": cloud_event.type,
                        "source": cloud_event.source,
                        "correlation_id": correlation_id,
                        "idempotency_key": idempotency_key,
                        "payload": cloud_event.model_dump_json(),
                        "scanned_at": cloud_event.time,
                    },
                )
                row = cur.fetchone()
                if row is None:
                    raise ScanStorageError("Failed to persist vehicle_received_scans record")

            conn.commit()
    except PsycopgError as error:
        raise ScanStorageError(f"Supabase DB error: {error}") from error

    return ScanStorageResult(record_id=row[0])


def save_vehicle_inventory_received_items(
    *,
    scan_id: str,
    cloud_event: VehicleInventoryReceivedCloudEvent,
) -> list[ScanItemStorageResult]:
    conn_str = _get_connection_string()
    results: list[ScanItemStorageResult] = []

    try:
        with connect(conn_str) as conn:
            with conn.cursor() as cur:
                for item in cloud_event.data.received_items:
                    cur.execute(
                        """
                        insert into public.vehicle_received_scan_items (
                            scan_id,
                            vin,
                            model,
                            odometer,
                            condition_score,
                            received_at,
                            item_status,
                            publish_attempts
                        ) values (
                            %(scan_id)s::uuid,
                            %(vin)s,
                            %(model)s,
                            %(odometer)s,
                            %(condition_score)s,
                            %(received_at)s,
                            'pending',
                            0
                        )
                        on conflict (scan_id, vin)
                        do update set
                            model = excluded.model,
                            odometer = excluded.odometer,
                            condition_score = excluded.condition_score,
                            received_at = excluded.received_at,
                            updated_at = now()
                        returning id::text
                        """,
                        {
                            "scan_id": scan_id,
                            "vin": item.vin,
                            "model": item.model,
                            "odometer": item.odometer,
                            "condition_score": item.condition,
                            "received_at": item.received_at,
                        },
                    )
                    row = cur.fetchone()
                    if row is None:
                        raise ScanStorageError("Failed to persist vehicle_received_scan_items record")
                    results.append(ScanItemStorageResult(item_record_id=row[0], vin=item.vin))
            conn.commit()
    except PsycopgError as error:
        raise ScanStorageError(f"Supabase DB error while writing batch items: {error}") from error

    return results


def update_vehicle_inventory_received_item_status(
    *,
    item_record_id: str,
    item_status: str,
    publish_attempts: int,
    publish_error: str | None,
    redpanda_event_id: str | None,
    redpanda_partition: int | None,
    redpanda_offset: int | None,
    published_at: datetime | None,
) -> None:
    conn_str = _get_connection_string()
    try:
        with connect(conn_str) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    update public.vehicle_received_scan_items
                    set
                        item_status = %(item_status)s,
                        publish_attempts = %(publish_attempts)s,
                        publish_error = %(publish_error)s,
                        redpanda_event_id = %(redpanda_event_id)s,
                        redpanda_partition = %(redpanda_partition)s,
                        redpanda_offset = %(redpanda_offset)s,
                        published_at = %(published_at)s,
                        updated_at = now()
                    where id = %(item_record_id)s::uuid
                    """,
                    {
                        "item_status": item_status,
                        "publish_attempts": publish_attempts,
                        "publish_error": publish_error,
                        "redpanda_event_id": redpanda_event_id,
                        "redpanda_partition": redpanda_partition,
                        "redpanda_offset": redpanda_offset,
                        "published_at": published_at,
                        "item_record_id": item_record_id,
                    },
                )
            conn.commit()
    except PsycopgError as error:
        raise ScanStorageError(
            f"Supabase DB error while updating batch item status: {error}"
        ) from error


def update_publish_status(
    *,
    record_id: str,
    publish_status: str,
    publish_attempts: int,
    publish_last_error: str | None,
    published_at: datetime | None,
) -> None:
    conn_str = _get_connection_string()
    try:
        with connect(conn_str) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    update public.vehicle_received_scans
                    set
                        publish_status = %(publish_status)s,
                        publish_attempts = %(publish_attempts)s,
                        publish_last_error = %(publish_last_error)s,
                        published_at = %(published_at)s,
                        updated_at = now()
                    where id = %(record_id)s::uuid
                    """,
                    {
                        "publish_status": publish_status,
                        "publish_attempts": publish_attempts,
                        "publish_last_error": publish_last_error,
                        "published_at": published_at,
                        "record_id": record_id,
                    },
                )
            conn.commit()
    except PsycopgError as error:
        raise ScanStorageError(f"Supabase DB error while updating publish status: {error}") from error


def utcnow() -> datetime:
    return datetime.now(timezone.utc)
