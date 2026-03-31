from datetime import datetime, timezone
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from app.models.cloud_events import GoodsReceivedVerifiedCloudEvent
from app.security.auth import AuthContext, get_auth_context
from app.services.odoo_jsonrpc import OdooJsonRpcError, get_odoo_client


router = APIRouter(prefix="/v1/integrations/odoo", tags=["odoo"])


class OdooHealthResponse(BaseModel):
    status: Literal["ok"]
    uid: int = Field(ge=1)
    checked_at: datetime


class OdooSyncResponse(BaseModel):
    status: Literal["ok"]
    event_id: str = Field(min_length=1, max_length=128)
    purchase_order: str = Field(min_length=1, max_length=128)
    po_id: int = Field(ge=1)
    receipt_id: int | None = Field(default=None, ge=1)
    product_id: int | None = Field(default=None, ge=1)
    lot_id: int | None = Field(default=None, ge=1)
    message: str = Field(min_length=1, max_length=500)
    synced_at: datetime


class OdooExecuteRequest(BaseModel):
    model: str = Field(min_length=1, max_length=128)
    method: str = Field(min_length=1, max_length=128)
    args: list[Any] = Field(default_factory=list)
    kwargs: dict[str, Any] = Field(default_factory=dict)


class OdooExecuteResponse(BaseModel):
    status: Literal["ok"]
    result: Any
    executed_at: datetime


@router.get("/health", response_model=OdooHealthResponse)
async def odoo_health_check(
    _auth_context: AuthContext = Depends(get_auth_context),
) -> OdooHealthResponse:
    client = get_odoo_client()
    try:
        uid = client.check_connection()
    except OdooJsonRpcError as error:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Odoo connectivity check failed: {error}",
        ) from error

    return OdooHealthResponse(
        status="ok",
        uid=uid,
        checked_at=datetime.now(timezone.utc),
    )


@router.post("/goods-received/sync", response_model=OdooSyncResponse)
async def sync_goods_received_to_odoo(
    cloud_event: GoodsReceivedVerifiedCloudEvent,
    _auth_context: AuthContext = Depends(get_auth_context),
) -> OdooSyncResponse:
    client = get_odoo_client()
    try:
        result = client.sync_goods_received_event(cloud_event)
    except OdooJsonRpcError as error:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Failed to sync event to Odoo: {error}",
        ) from error

    return OdooSyncResponse(
        status="ok",
        event_id=cloud_event.id,
        purchase_order=cloud_event.subject,
        po_id=result.po_id,
        receipt_id=result.receipt_id,
        product_id=result.product_id,
        lot_id=result.lot_id,
        message=result.message,
        synced_at=datetime.now(timezone.utc),
    )


@router.post("/jsonrpc/execute", response_model=OdooExecuteResponse)
async def execute_odoo_jsonrpc(
    payload: OdooExecuteRequest,
    _auth_context: AuthContext = Depends(get_auth_context),
) -> OdooExecuteResponse:
    client = get_odoo_client()
    try:
        result = client.execute_kw(
            model=payload.model,
            method=payload.method,
            args=payload.args,
            kwargs=payload.kwargs,
        )
    except OdooJsonRpcError as error:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Odoo JSON-RPC execute failed: {error}",
        ) from error

    return OdooExecuteResponse(
        status="ok",
        result=result,
        executed_at=datetime.now(timezone.utc),
    )

