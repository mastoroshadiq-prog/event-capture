from datetime import datetime
from typing import Generic, Literal, TypeVar

from pydantic import BaseModel, ConfigDict, Field

from app.models.cloud_events import HowData, WhatVehicleData, WhereData, WhoData, WhyData
from app.models.cloud_events import (
    GoodsReceivedVerifiedCloudEvent,
    GoodsReceivedVerifiedData,
    VehicleInventoryReceivedCloudEvent,
    VehicleInventoryReceivedData,
)


class ReceiptContext(BaseModel):
    when_scanned_at: datetime
    when_received_at: datetime | None = None
    condition_checklist: list[str] = Field(default_factory=list, max_length=50)
    notes: str | None = Field(default=None, max_length=500)


class InspectionContext(BaseModel):
    when_scanned_at: datetime
    when_inspected_at: datetime
    inspection_status: Literal["pass", "fail", "hold"]
    damage_codes: list[str] = Field(default_factory=list, max_length=100)
    notes: str | None = Field(default=None, max_length=500)


class IngestBaseRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    tenant_id: str = Field(min_length=1, max_length=64)
    source: str = Field(default="urn:warehouse:event-capture:android", min_length=1, max_length=255)
    who: WhoData
    what: WhatVehicleData
    where: WhereData
    why: WhyData
    how: HowData
    correlation_id: str | None = Field(default=None, max_length=128)


class VehicleReceivedIngestRequest(IngestBaseRequest):
    receipt: ReceiptContext


class VehicleInspectedIngestRequest(IngestBaseRequest):
    inspection: InspectionContext


class GoodsReceivedVerifiedIngestRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    specversion: Literal["1.0"] = "1.0"
    type: Literal["com.arista.inventory.goods_received.verified"] = (
        "com.arista.inventory.goods_received.verified"
    )
    source: str = Field(min_length=1, max_length=255)
    subject: str = Field(min_length=1, max_length=128)
    id: str = Field(min_length=1, max_length=128)
    time: datetime
    data: GoodsReceivedVerifiedData


class GoodsReceivedVerifiedRawIngestRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    receiving_id: str = Field(min_length=1, max_length=128)
    inspector_id: str = Field(min_length=1, max_length=64)
    vendor_name: str = Field(min_length=1, max_length=128)
    driver_id: str = Field(min_length=1, max_length=64)
    chassis_number: str = Field(min_length=17, max_length=17)
    engine_number: str = Field(min_length=1, max_length=64)
    model_code: str = Field(min_length=1, max_length=64)
    warehouse_id: str = Field(min_length=1, max_length=64)
    storage_zone: str = Field(min_length=1, max_length=64)
    parking_slot: str = Field(min_length=1, max_length=64)
    arrival_time: datetime
    purchase_order_ref: str = Field(min_length=1, max_length=128)
    delivery_note_ref: str = Field(min_length=1, max_length=128)

    condition_notes: str = Field(default="Good - No Scratch", min_length=1, max_length=500)
    landed_cost_actual: float = Field(default=0, ge=0)
    source: str = Field(default="arista:branch:jkt-pusat", min_length=1, max_length=255)
    event_type: Literal["com.arista.inventory.goods_received.verified"] = (
        "com.arista.inventory.goods_received.verified"
    )


class VehicleInventoryReceivedIngestRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    specversion: Literal["1.0"] = "1.0"
    type: Literal["com.arista.vehicle.inventory.received.v1"] = (
        "com.arista.vehicle.inventory.received.v1"
    )
    source: str = Field(min_length=1, max_length=255)
    subject: str = Field(min_length=1, max_length=128)
    id: str = Field(min_length=1, max_length=128)
    time: datetime
    datacontenttype: Literal["application/json"] = "application/json"
    data: VehicleInventoryReceivedData


TCloudEvent = TypeVar("TCloudEvent")


class IngestAcceptedResponse(BaseModel, Generic[TCloudEvent]):
    status: Literal["accepted"]
    event_type: str = Field(min_length=1, max_length=64)
    event_id: str = Field(min_length=1, max_length=128)
    correlation_id: str = Field(min_length=1, max_length=128)
    accepted_at: datetime
    publish_status: Literal["published", "dead-lettered"] = "published"
    publish_attempts: int = Field(default=0, ge=0)
    publish_duration_ms: int = Field(default=0, ge=0)
    dead_letter_id: str | None = Field(default=None, max_length=128)
    cloud_event: TCloudEvent


class ItemPublishStatus(BaseModel):
    vin: str = Field(min_length=17, max_length=17)
    status: Literal["pending", "processing", "published", "failed"]
    attempts: int = Field(default=0, ge=0)
    error: str | None = None
    redpanda_event_id: str | None = None
    redpanda_partition: int | None = None
    redpanda_offset: int | None = None


class BatchIngestAcceptedResponse(BaseModel):
    status: Literal["accepted"]
    event_type: str = Field(min_length=1, max_length=64)
    event_id: str = Field(min_length=1, max_length=128)
    correlation_id: str = Field(min_length=1, max_length=128)
    accepted_at: datetime
    publish_status: Literal["published", "dead-lettered", "partial"]
    publish_attempts: int = Field(default=0, ge=0)
    publish_duration_ms: int = Field(default=0, ge=0)
    dead_letter_id: str | None = Field(default=None, max_length=128)
    cloud_event: VehicleInventoryReceivedCloudEvent
    item_statuses: list[ItemPublishStatus] = Field(default_factory=list)

