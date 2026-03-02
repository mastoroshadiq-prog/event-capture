import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from pydantic import BaseModel

from app.core.settings import get_settings


@dataclass
class DeadLetterResult:
    dead_letter_id: str
    file_path: str


class DeadLetterService:
    def __init__(self) -> None:
        self._settings = get_settings()

    def write(
        self,
        *,
        cloud_event: BaseModel,
        reason: str,
        error_message: str,
        correlation_id: str,
        event_id: str,
        event_type: str,
    ) -> DeadLetterResult:
        base_dir = Path(self._settings.dead_letter_dir)
        base_dir.mkdir(parents=True, exist_ok=True)

        dead_letter_id = str(uuid4())
        file_name = (
            f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
            f"_{dead_letter_id}.json"
        )
        target_path = base_dir / file_name

        payload = {
            "dead_letter_id": dead_letter_id,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "reason": reason,
            "error_message": error_message,
            "correlation_id": correlation_id,
            "event_id": event_id,
            "event_type": event_type,
            "cloud_event": cloud_event.model_dump(mode="json"),
        }

        target_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        return DeadLetterResult(dead_letter_id=dead_letter_id, file_path=str(target_path))


_dead_letter_service = DeadLetterService()


def get_dead_letter_service() -> DeadLetterService:
    return _dead_letter_service

