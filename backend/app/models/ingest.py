from datetime import datetime
from typing import Generic, Literal, TypeVar

from pydantic import BaseModel, ConfigDict, Field

from app.models.cloud_events import HowData, WhatVehicleData, WhereData, WhoData, WhyData


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

