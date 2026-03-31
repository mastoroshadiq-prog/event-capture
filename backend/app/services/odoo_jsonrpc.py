from __future__ import annotations

import json
from dataclasses import dataclass
from ssl import SSLContext, _create_unverified_context, create_default_context
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import uuid4

from app.core.settings import get_settings
from app.models.cloud_events import GoodsReceivedVerifiedCloudEvent


class OdooJsonRpcError(RuntimeError):
    """Raised when Odoo JSON-RPC interaction fails."""


@dataclass(frozen=True)
class OdooSyncResult:
    po_id: int
    receipt_id: int | None
    product_id: int | None
    lot_id: int | None
    message: str


class OdooJsonRpcClient:
    def __init__(self) -> None:
        self._settings = get_settings()
        self._uid: int | None = None

    def _require_config(self) -> tuple[str, str, str, str]:
        base_url = (self._settings.odoo_base_url or "").strip()
        database = (self._settings.odoo_database or "").strip()
        username = (self._settings.odoo_username or "").strip()
        api_key = (self._settings.odoo_api_key or "").strip()

        if not base_url:
            raise OdooJsonRpcError("ODOO_BASE_URL is not configured")
        if not database:
            raise OdooJsonRpcError("ODOO_DATABASE is not configured")
        if not username:
            raise OdooJsonRpcError("ODOO_USERNAME is not configured")
        if not api_key:
            raise OdooJsonRpcError("ODOO_API_KEY is not configured")

        return base_url.rstrip("/"), database, username, api_key

    def _ssl_context(self) -> SSLContext:
        if self._settings.odoo_verify_ssl:
            return create_default_context()
        return _create_unverified_context()

    def _call(self, *, service: str, method: str, args: list[object]) -> object:
        base_url, _, _, _ = self._require_config()
        endpoint = f"{base_url}/jsonrpc"
        request_payload = {
            "jsonrpc": "2.0",
            "method": "call",
            "params": {
                "service": service,
                "method": method,
                "args": args,
            },
            "id": str(uuid4()),
        }
        payload_bytes = json.dumps(request_payload).encode("utf-8")
        request = Request(
            endpoint,
            data=payload_bytes,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        try:
            with urlopen(
                request,
                timeout=self._settings.odoo_timeout_seconds,
                context=self._ssl_context(),
            ) as response:
                raw_body = response.read().decode("utf-8")
        except HTTPError as error:
            detail = error.read().decode("utf-8", errors="ignore")
            raise OdooJsonRpcError(
                f"Odoo HTTP error {error.code}: {detail or error.reason}"
            ) from error
        except URLError as error:
            raise OdooJsonRpcError(f"Failed to connect to Odoo: {error.reason}") from error

        try:
            body = json.loads(raw_body)
        except json.JSONDecodeError as error:
            raise OdooJsonRpcError(f"Invalid JSON response from Odoo: {raw_body}") from error

        if body.get("error"):
            error_data = body["error"]
            message = error_data.get("message") if isinstance(error_data, dict) else str(error_data)
            raise OdooJsonRpcError(f"Odoo JSON-RPC error: {message}")

        return body.get("result")

    def authenticate(self) -> int:
        if self._uid is not None:
            return self._uid

        _, database, username, api_key = self._require_config()
        result = self._call(
            service="common",
            method="authenticate",
            args=[database, username, api_key, {}],
        )
        if not isinstance(result, int) or result <= 0:
            raise OdooJsonRpcError("Odoo authentication failed (invalid uid result)")
        self._uid = result
        return result

    def execute_kw(
        self,
        *,
        model: str,
        method: str,
        args: list[object] | None = None,
        kwargs: dict[str, object] | None = None,
    ) -> object:
        _, database, _, api_key = self._require_config()
        uid = self.authenticate()

        return self._call(
            service="object",
            method="execute_kw",
            args=[database, uid, api_key, model, method, args or [], kwargs or {}],
        )

    def check_connection(self) -> int:
        return self.authenticate()

    def _find_product_id(self, product_ref: str) -> int | None:
        if not product_ref:
            return None

        exact = self.execute_kw(
            model="product.product",
            method="search_read",
            args=[[["default_code", "=", product_ref]]],
            kwargs={"fields": ["id", "default_code", "name"], "limit": 1},
        )
        if isinstance(exact, list) and exact:
            candidate = exact[0]
            if isinstance(candidate, dict) and isinstance(candidate.get("id"), int):
                return candidate["id"]

        by_name = self.execute_kw(
            model="product.product",
            method="search_read",
            args=[[["name", "ilike", product_ref]]],
            kwargs={"fields": ["id", "default_code", "name"], "limit": 1},
        )
        if isinstance(by_name, list) and by_name:
            candidate = by_name[0]
            if isinstance(candidate, dict) and isinstance(candidate.get("id"), int):
                return candidate["id"]

        return None

    def sync_goods_received_event(self, cloud_event: GoodsReceivedVerifiedCloudEvent) -> OdooSyncResult:
        po_number = cloud_event.subject
        purchase_orders = self.execute_kw(
            model="purchase.order",
            method="search_read",
            args=[[["name", "=", po_number]]],
            kwargs={"fields": ["id", "name", "state"], "limit": 1},
        )
        if not isinstance(purchase_orders, list) or not purchase_orders:
            raise OdooJsonRpcError(f"Purchase Order not found in Odoo: {po_number}")

        po_row = purchase_orders[0]
        if not isinstance(po_row, dict) or not isinstance(po_row.get("id"), int):
            raise OdooJsonRpcError("Invalid purchase.order response from Odoo")
        po_id = po_row["id"]

        candidate_receipts = self.execute_kw(
            model="stock.picking",
            method="search_read",
            args=[
                [
                    ["purchase_id", "=", po_id],
                    ["picking_type_code", "=", "incoming"],
                    ["state", "not in", ["done", "cancel"]],
                ]
            ],
            kwargs={"fields": ["id", "name", "state"], "limit": 1},
        )

        receipt_id: int | None = None
        if isinstance(candidate_receipts, list) and candidate_receipts:
            receipt_row = candidate_receipts[0]
            if isinstance(receipt_row, dict) and isinstance(receipt_row.get("id"), int):
                receipt_id = receipt_row["id"]

        product_id = self._find_product_id(cloud_event.data.product_id)

        lot_id: int | None = None
        if product_id is not None:
            existing_lot = self.execute_kw(
                model="stock.lot",
                method="search_read",
                args=[
                    [
                        ["name", "=", cloud_event.data.vin_number],
                        ["product_id", "=", product_id],
                    ]
                ],
                kwargs={"fields": ["id", "name"], "limit": 1},
            )
            if isinstance(existing_lot, list) and existing_lot:
                lot_row = existing_lot[0]
                if isinstance(lot_row, dict) and isinstance(lot_row.get("id"), int):
                    lot_id = lot_row["id"]

            if lot_id is None:
                created = self.execute_kw(
                    model="stock.lot",
                    method="create",
                    args=[
                        {
                            "name": cloud_event.data.vin_number,
                            "product_id": product_id,
                        }
                    ],
                )
                if isinstance(created, int) and created > 0:
                    lot_id = created

        chatter_message = (
            "[Redpanda Event] "
            f"event_id={cloud_event.id}; "
            f"vin={cloud_event.data.vin_number}; "
            f"operator={cloud_event.data.operator_id}; "
            f"condition={cloud_event.data.condition_notes}; "
            f"landed_cost_actual={cloud_event.data.landed_cost_actual}"
        )
        self.execute_kw(
            model="purchase.order",
            method="message_post",
            args=[[po_id]],
            kwargs={"body": chatter_message, "message_type": "comment"},
        )

        return OdooSyncResult(
            po_id=po_id,
            receipt_id=receipt_id,
            product_id=product_id,
            lot_id=lot_id,
            message="Event synced to Odoo (PO matched, chatter updated, lot ensured when product matched)",
        )


_odoo_client = OdooJsonRpcClient()


def get_odoo_client() -> OdooJsonRpcClient:
    return _odoo_client

