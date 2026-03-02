import hashlib
import json
from dataclasses import dataclass
from threading import Lock
from typing import Generic, Literal, TypeVar

from fastapi import HTTPException, status
from pydantic import BaseModel


TModel = TypeVar("TModel", bound=BaseModel)


@dataclass
class IdempotencyRecord:
    event_type: str
    payload_hash: str
    cloud_event_json: str
    publish_status: Literal["published", "dead-lettered"]
    publish_attempts: int
    publish_duration_ms: int
    dead_letter_id: str | None


@dataclass
class IdempotencyLookup(Generic[TModel]):
    cloud_event: TModel
    publish_status: Literal["published", "dead-lettered"]
    publish_attempts: int
    publish_duration_ms: int
    dead_letter_id: str | None


class InMemoryIdempotencyStore:
    def __init__(self) -> None:
        self._records: dict[str, IdempotencyRecord] = {}
        self._lock = Lock()

    def validate_or_get_existing(
        self,
        *,
        idempotency_key: str | None,
        event_type: str,
        payload_hash: str,
        model_type: type[TModel],
    ) -> IdempotencyLookup[TModel] | None:
        if not idempotency_key:
            return None

        with self._lock:
            record = self._records.get(idempotency_key)
            if record is None:
                return None

            if record.event_type != event_type:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Idempotency key reused for different event type",
                )

            if record.payload_hash != payload_hash:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Idempotency key reused with different payload",
                )

            return IdempotencyLookup[TModel](
                cloud_event=model_type.model_validate_json(record.cloud_event_json),
                publish_status=record.publish_status,
                publish_attempts=record.publish_attempts,
                publish_duration_ms=record.publish_duration_ms,
                dead_letter_id=record.dead_letter_id,
            )

    def save(
        self,
        *,
        idempotency_key: str | None,
        event_type: str,
        payload_hash: str,
        cloud_event: BaseModel,
        publish_status: Literal["published", "dead-lettered"],
        publish_attempts: int,
        publish_duration_ms: int,
        dead_letter_id: str | None,
    ) -> None:
        if not idempotency_key:
            return

        with self._lock:
            self._records[idempotency_key] = IdempotencyRecord(
                event_type=event_type,
                payload_hash=payload_hash,
                cloud_event_json=cloud_event.model_dump_json(),
                publish_status=publish_status,
                publish_attempts=publish_attempts,
                publish_duration_ms=publish_duration_ms,
                dead_letter_id=dead_letter_id,
            )


def build_payload_hash(payload: BaseModel) -> str:
    canonical_payload = json.dumps(
        payload.model_dump(mode="json"),
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical_payload.encode("utf-8")).hexdigest()


_idempotency_store = InMemoryIdempotencyStore()


def get_idempotency_store() -> InMemoryIdempotencyStore:
    return _idempotency_store

