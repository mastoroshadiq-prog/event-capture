from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Header, status

from app.models.cloud_events import (
    GoodsReceivedVerifiedCloudEvent,
    VehicleInspectedCloudEvent,
    VehicleInventoryReceivedCloudEvent,
    VehicleReceivedCloudEvent,
)
from app.models.ingest import (
    BatchIngestAcceptedResponse,
    GoodsReceivedVerifiedIngestRequest,
    GoodsReceivedVerifiedRawIngestRequest,
    IngestAcceptedResponse,
    ItemPublishStatus,
    VehicleInventoryReceivedIngestRequest,
    VehicleInspectedIngestRequest,
    VehicleReceivedIngestRequest,
)
from app.services.event_factory import (
    build_goods_received_verified_cloudevent,
    build_goods_received_verified_cloudevent_from_raw,
    build_vehicle_inventory_received_cloudevent,
    build_vehicle_inspected_cloudevent,
    build_vehicle_received_cloudevent,
)
from app.services.dead_letter import get_dead_letter_service
from app.services.idempotency import build_payload_hash, get_idempotency_store
from app.services.redpanda_publisher import EventPublishError, get_redpanda_publisher
from app.services.scan_storage import (
    ScanItemStorageResult,
    ScanStorageError,
    save_goods_received_scan,
    save_vehicle_inventory_received_items,
    save_vehicle_inventory_received_scan,
    update_vehicle_inventory_received_item_status,
    update_publish_status,
    utcnow,
)
from app.security.auth import (
    AuthContext,
    enforce_ingest_authorization,
    get_auth_context,
)


router = APIRouter(prefix="/v1/events", tags=["events"])


@router.post(
    "/vehicle-received/batch",
    response_model=BatchIngestAcceptedResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def ingest_vehicle_received_batch(
    payload: VehicleInventoryReceivedIngestRequest,
    x_correlation_id: str | None = Header(default=None),
    x_idempotency_key: str | None = Header(default=None),
    auth_context: AuthContext = Depends(get_auth_context),
) -> BatchIngestAcceptedResponse:
    idempotency_key = x_idempotency_key.strip() if x_idempotency_key else None
    correlation_id = x_correlation_id.strip() if x_correlation_id else None

    enforce_ingest_authorization(
        auth_context,
        payload_operator_id=payload.data.receiving_context.inspector_id,
        payload_device_id="mobile-scanner",
    )

    payload_hash = build_payload_hash(payload)
    idempotency_store = get_idempotency_store()
    existing_event = idempotency_store.validate_or_get_existing(
        idempotency_key=idempotency_key,
        event_type="vehicle.received.batch",
        payload_hash=payload_hash,
        model_type=VehicleInventoryReceivedCloudEvent,
    )
    if existing_event is not None:
        return BatchIngestAcceptedResponse(
            status="accepted",
            event_type=existing_event.cloud_event.type,
            event_id=existing_event.cloud_event.id,
            correlation_id=correlation_id or existing_event.cloud_event.id,
            accepted_at=datetime.now(timezone.utc),
            publish_status=existing_event.publish_status,
            publish_attempts=existing_event.publish_attempts,
            publish_duration_ms=existing_event.publish_duration_ms,
            dead_letter_id=existing_event.dead_letter_id,
            cloud_event=existing_event.cloud_event,
            item_statuses=[],
        )

    cloud_event = build_vehicle_inventory_received_cloudevent(
        payload=payload,
        idempotency_key=idempotency_key,
    )
    correlation_value = correlation_id or cloud_event.id

    try:
        storage_result = save_vehicle_inventory_received_scan(
            cloud_event=cloud_event,
            correlation_id=correlation_value,
            idempotency_key=idempotency_key,
        )
        item_storage_results = save_vehicle_inventory_received_items(
            scan_id=storage_result.record_id,
            cloud_event=cloud_event,
        )
    except ScanStorageError as error:
        from fastapi import HTTPException

        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to persist scan data: {error}",
        ) from error

    publisher = get_redpanda_publisher()
    dead_letter_service = get_dead_letter_service()
    item_statuses: list[ItemPublishStatus] = []
    total_attempts = 0
    total_duration_ms = 0
    published_count = 0
    dead_letter_id: str | None = None

    item_by_vin: dict[str, ScanItemStorageResult] = {i.vin: i for i in item_storage_results}

    for item in cloud_event.data.received_items:
        item_event_id = f"{cloud_event.id}:{item.vin}"
        item_event = cloud_event.model_copy(
            update={
                "id": item_event_id,
                "time": item.received_at,
                "data": {
                    "receiving_context": cloud_event.data.receiving_context.model_dump(),
                    "received_items": [item.model_dump()],
                },
            }
        )

        storage_item = item_by_vin.get(item.vin)
        if storage_item is None:
            continue

        try:
            publish_result = publisher.publish(
                item_event,
                correlation_id=correlation_value,
                event_id=item_event_id,
                event_type=cloud_event.type,
                partition_key=item.vin,
            )

            published_count += 1
            total_attempts += publish_result.attempts
            total_duration_ms += publish_result.duration_ms

            update_vehicle_inventory_received_item_status(
                item_record_id=storage_item.item_record_id,
                item_status="published",
                publish_attempts=publish_result.attempts,
                publish_error=None,
                redpanda_event_id=item_event_id,
                redpanda_partition=None,
                redpanda_offset=None,
                published_at=utcnow(),
            )

            item_statuses.append(
                ItemPublishStatus(
                    vin=item.vin,
                    status="published",
                    attempts=publish_result.attempts,
                    error=None,
                    redpanda_event_id=item_event_id,
                    redpanda_partition=None,
                    redpanda_offset=None,
                )
            )
        except EventPublishError as error:
            dlq_result = dead_letter_service.write(
                cloud_event=item_event,
                reason="redpanda_publish_failed",
                error_message=str(error),
                correlation_id=correlation_value,
                event_id=item_event_id,
                event_type=cloud_event.type,
            )
            dead_letter_id = dead_letter_id or dlq_result.dead_letter_id

            update_vehicle_inventory_received_item_status(
                item_record_id=storage_item.item_record_id,
                item_status="failed",
                publish_attempts=0,
                publish_error=str(error),
                redpanda_event_id=item_event_id,
                redpanda_partition=None,
                redpanda_offset=None,
                published_at=None,
            )

            item_statuses.append(
                ItemPublishStatus(
                    vin=item.vin,
                    status="failed",
                    attempts=0,
                    error=str(error),
                    redpanda_event_id=item_event_id,
                    redpanda_partition=None,
                    redpanda_offset=None,
                )
            )

    if published_count == len(cloud_event.data.received_items):
        publish_status = "published"
    elif published_count == 0:
        publish_status = "dead-lettered"
    else:
        publish_status = "partial"

    publish_attempts = total_attempts
    publish_duration_ms = total_duration_ms

    update_publish_status(
        record_id=storage_result.record_id,
        publish_status="published" if publish_status == "published" else "dead-lettered",
        publish_attempts=publish_attempts,
        publish_last_error=None
        if publish_status == "published"
        else "One or more item publishes failed",
        published_at=utcnow() if publish_status == "published" else None,
    )

    idempotency_store.save(
        idempotency_key=idempotency_key,
        event_type="vehicle.received.batch",
        payload_hash=payload_hash,
        cloud_event=cloud_event,
        publish_status=publish_status,
        publish_attempts=publish_attempts,
        publish_duration_ms=publish_duration_ms,
        dead_letter_id=dead_letter_id,
    )

    return BatchIngestAcceptedResponse(
        status="accepted",
        event_type=cloud_event.type,
        event_id=cloud_event.id,
        correlation_id=correlation_value,
        accepted_at=datetime.now(timezone.utc),
        publish_status=publish_status,
        publish_attempts=publish_attempts,
        publish_duration_ms=publish_duration_ms,
        dead_letter_id=dead_letter_id,
        cloud_event=cloud_event,
        item_statuses=item_statuses,
    )


@router.post(
    "/vehicle-received",
    response_model=IngestAcceptedResponse[GoodsReceivedVerifiedCloudEvent],
    status_code=status.HTTP_202_ACCEPTED,
)
async def ingest_vehicle_received(
    payload: GoodsReceivedVerifiedIngestRequest,
    x_correlation_id: str | None = Header(default=None),
    x_idempotency_key: str | None = Header(default=None),
    auth_context: AuthContext = Depends(get_auth_context),
) -> IngestAcceptedResponse[GoodsReceivedVerifiedCloudEvent]:
    idempotency_key = x_idempotency_key.strip() if x_idempotency_key else None
    correlation_id = x_correlation_id.strip() if x_correlation_id else None

    enforce_ingest_authorization(
        auth_context,
        payload_operator_id=payload.data.operator_id,
        payload_device_id="mobile-scanner",
    )

    payload_hash = build_payload_hash(payload)
    idempotency_store = get_idempotency_store()
    existing_event = idempotency_store.validate_or_get_existing(
        idempotency_key=idempotency_key,
        event_type="vehicle.received",
        payload_hash=payload_hash,
        model_type=GoodsReceivedVerifiedCloudEvent,
    )
    if existing_event is not None:
        return IngestAcceptedResponse[GoodsReceivedVerifiedCloudEvent](
            status="accepted",
            event_type=existing_event.cloud_event.type,
            event_id=existing_event.cloud_event.id,
            correlation_id=correlation_id or existing_event.cloud_event.id,
            accepted_at=datetime.now(timezone.utc),
            publish_status=existing_event.publish_status,
            publish_attempts=existing_event.publish_attempts,
            publish_duration_ms=existing_event.publish_duration_ms,
            dead_letter_id=existing_event.dead_letter_id,
            cloud_event=existing_event.cloud_event,
        )

    cloud_event = build_goods_received_verified_cloudevent(
        payload=payload,
        idempotency_key=idempotency_key,
    )
    correlation_value = correlation_id or cloud_event.id

    try:
        storage_result = save_goods_received_scan(
            cloud_event=cloud_event,
            correlation_id=correlation_value,
            idempotency_key=idempotency_key,
        )
    except ScanStorageError as error:
        from fastapi import HTTPException

        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to persist scan data: {error}",
        ) from error

    publisher = get_redpanda_publisher()
    dead_letter_service = get_dead_letter_service()

    try:
        publish_result = publisher.publish(
            cloud_event,
            correlation_id=correlation_value,
            event_id=cloud_event.id,
            event_type=cloud_event.type,
            partition_key=cloud_event.data.vin_number,
        )
        publish_status = "published"
        publish_attempts = publish_result.attempts
        publish_duration_ms = publish_result.duration_ms
        dead_letter_id = None
        update_publish_status(
            record_id=storage_result.record_id,
            publish_status=publish_status,
            publish_attempts=publish_attempts,
            publish_last_error=None,
            published_at=utcnow(),
        )
    except EventPublishError as error:
        dlq_result = dead_letter_service.write(
            cloud_event=cloud_event,
            reason="redpanda_publish_failed",
            error_message=str(error),
            correlation_id=correlation_value,
            event_id=cloud_event.id,
            event_type=cloud_event.type,
        )
        publish_status = "dead-lettered"
        publish_attempts = 0
        publish_duration_ms = 0
        dead_letter_id = dlq_result.dead_letter_id
        update_publish_status(
            record_id=storage_result.record_id,
            publish_status=publish_status,
            publish_attempts=publish_attempts,
            publish_last_error=str(error),
            published_at=None,
        )

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

    return IngestAcceptedResponse[GoodsReceivedVerifiedCloudEvent](
        status="accepted",
        event_type=cloud_event.type,
        event_id=cloud_event.id,
        correlation_id=correlation_value,
        accepted_at=datetime.now(timezone.utc),
        publish_status=publish_status,
        publish_attempts=publish_attempts,
        publish_duration_ms=publish_duration_ms,
        dead_letter_id=dead_letter_id,
        cloud_event=cloud_event,
    )


@router.post(
    "/vehicle-received/raw",
    response_model=IngestAcceptedResponse[GoodsReceivedVerifiedCloudEvent],
    status_code=status.HTTP_202_ACCEPTED,
)
async def ingest_vehicle_received_raw(
    payload: GoodsReceivedVerifiedRawIngestRequest,
    x_correlation_id: str | None = Header(default=None),
    x_idempotency_key: str | None = Header(default=None),
    auth_context: AuthContext = Depends(get_auth_context),
) -> IngestAcceptedResponse[GoodsReceivedVerifiedCloudEvent]:
    idempotency_key = x_idempotency_key.strip() if x_idempotency_key else None
    correlation_id = x_correlation_id.strip() if x_correlation_id else None

    enforce_ingest_authorization(
        auth_context,
        payload_operator_id=payload.inspector_id,
        payload_device_id="mobile-scanner",
    )

    payload_hash = build_payload_hash(payload)
    idempotency_store = get_idempotency_store()
    existing_event = idempotency_store.validate_or_get_existing(
        idempotency_key=idempotency_key,
        event_type="vehicle.received.raw",
        payload_hash=payload_hash,
        model_type=GoodsReceivedVerifiedCloudEvent,
    )
    if existing_event is not None:
        return IngestAcceptedResponse[GoodsReceivedVerifiedCloudEvent](
            status="accepted",
            event_type=existing_event.cloud_event.type,
            event_id=existing_event.cloud_event.id,
            correlation_id=correlation_id or existing_event.cloud_event.id,
            accepted_at=datetime.now(timezone.utc),
            publish_status=existing_event.publish_status,
            publish_attempts=existing_event.publish_attempts,
            publish_duration_ms=existing_event.publish_duration_ms,
            dead_letter_id=existing_event.dead_letter_id,
            cloud_event=existing_event.cloud_event,
        )

    cloud_event = build_goods_received_verified_cloudevent_from_raw(
        payload=payload,
        idempotency_key=idempotency_key,
    )
    correlation_value = correlation_id or cloud_event.id

    try:
        storage_result = save_goods_received_scan(
            cloud_event=cloud_event,
            correlation_id=correlation_value,
            idempotency_key=idempotency_key,
        )
    except ScanStorageError as error:
        from fastapi import HTTPException

        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to persist scan data: {error}",
        ) from error

    publisher = get_redpanda_publisher()
    dead_letter_service = get_dead_letter_service()

    try:
        publish_result = publisher.publish(
            cloud_event,
            correlation_id=correlation_value,
            event_id=cloud_event.id,
            event_type=cloud_event.type,
            partition_key=cloud_event.data.vin_number,
        )
        publish_status = "published"
        publish_attempts = publish_result.attempts
        publish_duration_ms = publish_result.duration_ms
        dead_letter_id = None
        update_publish_status(
            record_id=storage_result.record_id,
            publish_status=publish_status,
            publish_attempts=publish_attempts,
            publish_last_error=None,
            published_at=utcnow(),
        )
    except EventPublishError as error:
        dlq_result = dead_letter_service.write(
            cloud_event=cloud_event,
            reason="redpanda_publish_failed",
            error_message=str(error),
            correlation_id=correlation_value,
            event_id=cloud_event.id,
            event_type=cloud_event.type,
        )
        publish_status = "dead-lettered"
        publish_attempts = 0
        publish_duration_ms = 0
        dead_letter_id = dlq_result.dead_letter_id
        update_publish_status(
            record_id=storage_result.record_id,
            publish_status=publish_status,
            publish_attempts=publish_attempts,
            publish_last_error=str(error),
            published_at=None,
        )

    idempotency_store.save(
        idempotency_key=idempotency_key,
        event_type="vehicle.received.raw",
        payload_hash=payload_hash,
        cloud_event=cloud_event,
        publish_status=publish_status,
        publish_attempts=publish_attempts,
        publish_duration_ms=publish_duration_ms,
        dead_letter_id=dead_letter_id,
    )

    return IngestAcceptedResponse[GoodsReceivedVerifiedCloudEvent](
        status="accepted",
        event_type=cloud_event.type,
        event_id=cloud_event.id,
        correlation_id=correlation_value,
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

