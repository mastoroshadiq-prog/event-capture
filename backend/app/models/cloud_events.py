from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class WhoData(BaseModel):
    operator_id: str = Field(min_length=1, max_length=64)
    inspector_id: str | None = Field(default=None, max_length=64)
    vendor_id: str | None = Field(default=None, max_length=64)


class WhatVehicleData(BaseModel):
    vin: str = Field(min_length=17, max_length=17)
    shipment_id: str = Field(min_length=1, max_length=64)
    model_code: str | None = Field(default=None, max_length=64)
    color_code: str | None = Field(default=None, max_length=32)
    raw_scan_value: str = Field(min_length=1, max_length=256)


class WhereData(BaseModel):
    warehouse_id: str = Field(min_length=1, max_length=64)
    gate_id: str | None = Field(default=None, max_length=64)
    latitude: float | None = None
    longitude: float | None = None


class WhyData(BaseModel):
    business_process: str = Field(default="inbound_receipt", min_length=1, max_length=64)
    reason_code: str = Field(default="apm_delivery", min_length=1, max_length=64)


class HowData(BaseModel):
    scan_method: Literal["barcode", "qrcode", "manual"]
    app_version: str = Field(min_length=1, max_length=32)
    device_id: str = Field(min_length=1, max_length=128)


class VehicleReceivedEventData(BaseModel):
    model_config = ConfigDict(extra="forbid")

    who: WhoData
    what: WhatVehicleData
    when_scanned_at: datetime
    when_received_at: datetime | None = None
    where: WhereData
    why: WhyData
    how: HowData
    condition_checklist: list[str] = Field(default_factory=list, max_length=50)
    notes: str | None = Field(default=None, max_length=500)


class VehicleInspectedEventData(BaseModel):
    model_config = ConfigDict(extra="forbid")

    who: WhoData
    what: WhatVehicleData
    when_scanned_at: datetime
    when_inspected_at: datetime
    where: WhereData
    why: WhyData
    how: HowData
    inspection_status: Literal["pass", "fail", "hold"]
    damage_codes: list[str] = Field(default_factory=list, max_length=100)
    notes: str | None = Field(default=None, max_length=500)


class CloudEventBase(BaseModel):
    model_config = ConfigDict(extra="forbid")

    specversion: Literal["1.0"] = "1.0"
    id: str = Field(min_length=1, max_length=128)
    source: str = Field(min_length=1, max_length=255)
    type: str = Field(min_length=1, max_length=64)
    subject: str | None = Field(default=None, max_length=128)
    time: datetime
    datacontenttype: Literal["application/json"] = "application/json"
    dataschema: str | None = Field(default=None, max_length=255)
    tenantid: str = Field(min_length=1, max_length=64)
    warehouseid: str = Field(min_length=1, max_length=64)
    gateid: str | None = Field(default=None, max_length=64)
    operatorid: str = Field(min_length=1, max_length=64)
    deviceid: str = Field(min_length=1, max_length=128)
    correlationid: str = Field(min_length=1, max_length=128)
    eventversion: Literal["v1"] = "v1"


class VehicleReceivedCloudEvent(CloudEventBase):
    type: Literal["vehicle.received"] = "vehicle.received"
    data: VehicleReceivedEventData


class VehicleInspectedCloudEvent(CloudEventBase):
    type: Literal["vehicle.inspected"] = "vehicle.inspected"
    data: VehicleInspectedEventData


class GoodsReceivedItemData(BaseModel):
    product_id: str = Field(min_length=1, max_length=64)
    vin_number: str = Field(min_length=17, max_length=17)
    condition_notes: str = Field(min_length=1, max_length=500)
    landed_cost_actual: float = Field(ge=0)


class GoodsReceivedVerifiedData(BaseModel):
    vendor_id: str = Field(min_length=1, max_length=64)
    operator_id: str = Field(min_length=1, max_length=64)
    item_list: GoodsReceivedItemData


class GoodsReceivedVerifiedCloudEvent(BaseModel):
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

