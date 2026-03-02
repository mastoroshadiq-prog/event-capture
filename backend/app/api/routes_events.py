from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Header, status

from app.models.cloud_events import VehicleInspectedCloudEvent, VehicleReceivedCloudEvent
from app.models.ingest import (
    IngestAcceptedResponse,
    VehicleInspectedIngestRequest,
    VehicleReceivedIngestRequest,
)
from app.services.event_factory import (
    build_vehicle_inspected_cloudevent,
    build_vehicle_received_cloudevent,
)
from app.services.dead_letter import get_dead_letter_service
from app.services.idempotency import build_payload_hash, get_idempotency_store
from app.services.redpanda_publisher import EventPublishError, get_redpanda_publisher
from app.security.auth import (
    AuthContext,
    enforce_ingest_authorization,
    get_auth_context,
)


router = APIRouter(prefix="/v1/events", tags=["events"])


@router.post(
    "/vehicle-received",
    response_model=IngestAcceptedResponse[VehicleReceivedCloudEvent],
    status_code=status.HTTP_202_ACCEPTED,
)
async def ingest_vehicle_received(
    payload: VehicleReceivedIngestRequest,
    x_correlation_id: str | None = Header(default=None),
    x_idempotency_key: str | None = Header(default=None),
    auth_context: AuthContext = Depends(get_auth_context),
) -> IngestAcceptedResponse[VehicleReceivedCloudEvent]:
    idempotency_key = x_idempotency_key.strip() if x_idempotency_key else None
    correlation_id = x_correlation_id.strip() if x_correlation_id else None

    enforce_ingest_authorization(
        auth_context,
        payload_operator_id=payload.who.operator_id,
        payload_device_id=payload.how.device_id,
    )

    payload_hash = build_payload_hash(payload)
    idempotency_store = get_idempotency_store()
    existing_event = idempotency_store.validate_or_get_existing(
        idempotency_key=idempotency_key,
        event_type="vehicle.received",
        payload_hash=payload_hash,
        model_type=VehicleReceivedCloudEvent,
    )
    if existing_event is not None:
        return IngestAcceptedResponse[VehicleReceivedCloudEvent](
            status="accepted",
            event_type=existing_event.cloud_event.type,
            event_id=existing_event.cloud_event.id,
            correlation_id=existing_event.cloud_event.correlationid,
            accepted_at=datetime.now(timezone.utc),
            publish_status=existing_event.publish_status,
            publish_attempts=existing_event.publish_attempts,
            publish_duration_ms=existing_event.publish_duration_ms,
            dead_letter_id=existing_event.dead_letter_id,
            cloud_event=existing_event.cloud_event,
        )

    cloud_event = build_vehicle_received_cloudevent(
        payload=payload,
        header_correlation_id=correlation_id,
        idempotency_key=idempotency_key,
    )

    publisher = get_redpanda_publisher()
    dead_letter_service = get_dead_letter_service()

    try:
        publish_result = publisher.publish(
            cloud_event,
            correlation_id=cloud_event.correlationid,
            event_id=cloud_event.id,
            event_type=cloud_event.type,
            partition_key=cloud_event.data.what.vin or cloud_event.data.what.shipment_id,
        )
        publish_status = "published"
        publish_attempts = publish_result.attempts
        publish_duration_ms = publish_result.duration_ms
        dead_letter_id = None
    except EventPublishError as error:
        dlq_result = dead_letter_service.write(
            cloud_event=cloud_event,
            reason="redpanda_publish_failed",
            error_message=str(error),
            correlation_id=cloud_event.correlationid,
            event_id=cloud_event.id,
            event_type=cloud_event.type,
        )
        publish_status = "dead-lettered"
        publish_attempts = 0
        publish_duration_ms = 0
        dead_letter_id = dlq_result.dead_letter_id

    idempotency_store.save(
        idempotency_key=idempotency_key,
        event_type="vehicle.received",
        payload_hash=payload_hash,
        cloud_event=cloud_event,
        publish_status=publish_status,
        publish_attempts=publish_attempts,
        publish_duration_ms=publish_duration_ms,
        dead_letter_id=dead_letter_id,
    )

    return IngestAcceptedResponse[VehicleReceivedCloudEvent](
        status="accepted",
        event_type=cloud_event.type,
        event_id=cloud_event.id,
        correlation_id=cloud_event.correlationid,
        accepted_at=datetime.now(timezone.utc),
        publish_status=publish_status,
        publish_attempts=publish_attempts,
        publish_duration_ms=publish_duration_ms,
        dead_letter_id=dead_letter_id,
        cloud_event=cloud_event,
    )


@router.post(
    "/vehicle-inspected",
    response_model=IngestAcceptedResponse[VehicleInspectedCloudEvent],
    status_code=status.HTTP_202_ACCEPTED,
)
async def ingest_vehicle_inspected(
    payload: VehicleInspectedIngestRequest,
    x_correlation_id: str | None = Header(default=None),
    x_idempotency_key: str | None = Header(default=None),
    auth_context: AuthContext = Depends(get_auth_context),
) -> IngestAcceptedResponse[VehicleInspectedCloudEvent]:
    idempotency_key = x_idempotency_key.strip() if x_idempotency_key else None
    correlation_id = x_correlation_id.strip() if x_correlation_id else None

    enforce_ingest_authorization(
        auth_context,
        payload_operator_id=payload.who.operator_id,
        payload_device_id=payload.how.device_id,
    )

    payload_hash = build_payload_hash(payload)
    idempotency_store = get_idempotency_store()
    existing_event = idempotency_store.validate_or_get_existing(
        idempotency_key=idempotency_key,
        event_type="vehicle.inspected",
        payload_hash=payload_hash,
        model_type=VehicleInspectedCloudEvent,
    )
    if existing_event is not None:
        return IngestAcceptedResponse[VehicleInspectedCloudEvent](
            status="accepted",
            event_type=existing_event.cloud_event.type,
            event_id=existing_event.cloud_event.id,
            correlation_id=existing_event.cloud_event.correlationid,
            accepted_at=datetime.now(timezone.utc),
            publish_status=existing_event.publish_status,
            publish_attempts=existing_event.publish_attempts,
            publish_duration_ms=existing_event.publish_duration_ms,
            dead_letter_id=existing_event.dead_letter_id,
            cloud_event=existing_event.cloud_event,
        )

    cloud_event = build_vehicle_inspected_cloudevent(
        payload=payload,
        header_correlation_id=correlation_id,
        idempotency_key=idempotency_key,
    )

    publisher = get_redpanda_publisher()
    dead_letter_service = get_dead_letter_service()

    try:
        publish_result = publisher.publish(
            cloud_event,
            correlation_id=cloud_event.correlationid,
            event_id=cloud_event.id,
            event_type=cloud_event.type,
            partition_key=cloud_event.data.what.vin or cloud_event.data.what.shipment_id,
        )
        publish_status = "published"
        publish_attempts = publish_result.attempts
        publish_duration_ms = publish_result.duration_ms
        dead_letter_id = None
    except EventPublishError as error:
        dlq_result = dead_letter_service.write(
            cloud_event=cloud_event,
            reason="redpanda_publish_failed",
            error_message=str(error),
            correlation_id=cloud_event.correlationid,
            event_id=cloud_event.id,
            event_type=cloud_event.type,
        )
        publish_status = "dead-lettered"
        publish_attempts = 0
        publish_duration_ms = 0
        dead_letter_id = dlq_result.dead_letter_id

    idempotency_store.save(
        idempotency_key=idempotency_key,
        event_type="vehicle.inspected",
        payload_hash=payload_hash,
        cloud_event=cloud_event,
        publish_status=publish_status,
        publish_attempts=publish_attempts,
        publish_duration_ms=publish_duration_ms,
        dead_letter_id=dead_letter_id,
    )

    return IngestAcceptedResponse[VehicleInspectedCloudEvent](
        status="accepted",
        event_type=cloud_event.type,
        event_id=cloud_event.id,
        correlation_id=cloud_event.correlationid,
        accepted_at=datetime.now(timezone.utc),
        publish_status=publish_status,
        publish_attempts=publish_attempts,
        publish_duration_ms=publish_duration_ms,
        dead_letter_id=dead_letter_id,
        cloud_event=cloud_event,
    )

