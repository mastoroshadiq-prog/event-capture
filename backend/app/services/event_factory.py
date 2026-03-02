from datetime import datetime, timezone
from uuid import uuid4

from app.models.cloud_events import (
    GoodsReceivedVerifiedCloudEvent,
    VehicleInspectedCloudEvent,
    VehicleInspectedEventData,
    VehicleReceivedCloudEvent,
    VehicleReceivedEventData,
)
from app.models.ingest import (
    GoodsReceivedVerifiedIngestRequest,
    VehicleInspectedIngestRequest,
    VehicleReceivedIngestRequest,
)


def _resolve_correlation_id(request_value: str | None, header_value: str | None) -> str:
    if request_value:
        return request_value
    if header_value:
        return header_value
    return str(uuid4())


def _resolve_event_id(idempotency_key: str | None) -> str:
    return idempotency_key or str(uuid4())


def build_vehicle_received_cloudevent(
    payload: VehicleReceivedIngestRequest,
    header_correlation_id: str | None,
    idempotency_key: str | None,
) -> VehicleReceivedCloudEvent:
    event_data = VehicleReceivedEventData(
        who=payload.who,
        what=payload.what,
        when_scanned_at=payload.receipt.when_scanned_at,
        when_received_at=payload.receipt.when_received_at,
        where=payload.where,
        why=payload.why,
        how=payload.how,
        condition_checklist=payload.receipt.condition_checklist,
        notes=payload.receipt.notes,
    )

    correlation_id = _resolve_correlation_id(payload.correlation_id, header_correlation_id)
    event_id = _resolve_event_id(idempotency_key)

    return VehicleReceivedCloudEvent(
        id=event_id,
        source=payload.source,
        subject=payload.what.vin,
        time=datetime.now(timezone.utc),
        dataschema="https://example.org/schema/cloudevents/vehicle.received.v1.json",
        tenantid=payload.tenant_id,
        warehouseid=payload.where.warehouse_id,
        gateid=payload.where.gate_id,
        operatorid=payload.who.operator_id,
        deviceid=payload.how.device_id,
        correlationid=correlation_id,
        data=event_data,
    )


def build_vehicle_inspected_cloudevent(
    payload: VehicleInspectedIngestRequest,
    header_correlation_id: str | None,
    idempotency_key: str | None,
) -> VehicleInspectedCloudEvent:
    event_data = VehicleInspectedEventData(
        who=payload.who,
        what=payload.what,
        when_scanned_at=payload.inspection.when_scanned_at,
        when_inspected_at=payload.inspection.when_inspected_at,
        where=payload.where,
        why=payload.why,
        how=payload.how,
        inspection_status=payload.inspection.inspection_status,
        damage_codes=payload.inspection.damage_codes,
        notes=payload.inspection.notes,
    )

    correlation_id = _resolve_correlation_id(payload.correlation_id, header_correlation_id)
    event_id = _resolve_event_id(idempotency_key)

    return VehicleInspectedCloudEvent(
        id=event_id,
        source=payload.source,
        subject=payload.what.vin,
        time=datetime.now(timezone.utc),
        dataschema="https://example.org/schema/cloudevents/vehicle.inspected.v1.json",
        tenantid=payload.tenant_id,
        warehouseid=payload.where.warehouse_id,
        gateid=payload.where.gate_id,
        operatorid=payload.who.operator_id,
        deviceid=payload.how.device_id,
        correlationid=correlation_id,
        data=event_data,
    )


def build_goods_received_verified_cloudevent(
    payload: GoodsReceivedVerifiedIngestRequest,
    idempotency_key: str | None,
) -> GoodsReceivedVerifiedCloudEvent:
    event_id = _resolve_event_id(idempotency_key)

    return GoodsReceivedVerifiedCloudEvent(
        specversion=payload.specversion,
        type=payload.type,
        source=payload.source,
        subject=payload.subject,
        id=event_id,
        time=payload.time,
        data=payload.data,
    )

