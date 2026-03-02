from datetime import datetime, timedelta, timezone
from time import perf_counter, sleep

from confluent_kafka import Producer
from pydantic import BaseModel

from app.core.settings import get_settings
from app.services.publish_result import PublishResult


class EventPublishError(Exception):
    """Raised when publish to Redpanda fails."""


class CircuitBreakerOpenError(EventPublishError):
    """Raised when circuit breaker is open and publish is blocked."""


class RedpandaPublisher:
    def __init__(self) -> None:
        self._settings = get_settings()
        self._failure_count = 0
        self._circuit_open_until: datetime | None = None

    def _is_circuit_open(self) -> bool:
        if self._circuit_open_until is None:
            return False
        now = datetime.now(timezone.utc)
        if now >= self._circuit_open_until:
            self._circuit_open_until = None
            self._failure_count = 0
            return False
        return True

    def _register_failure(self) -> None:
        self._failure_count += 1
        if self._failure_count >= self._settings.circuit_breaker_failure_threshold:
            self._circuit_open_until = datetime.now(timezone.utc) + timedelta(
                seconds=self._settings.circuit_breaker_reset_seconds
            )

    def _register_success(self) -> None:
        self._failure_count = 0
        self._circuit_open_until = None

    def _build_producer(self) -> Producer:
        if not self._settings.redpanda_bootstrap_servers:
            raise EventPublishError("REDPANDA_BOOTSTRAP_SERVERS is not configured")
        if not self._settings.redpanda_topic:
            raise EventPublishError("REDPANDA_TOPIC is not configured")

        config: dict[str, str] = {
            "bootstrap.servers": self._settings.redpanda_bootstrap_servers,
            "client.id": self._settings.redpanda_client_id,
            "acks": self._settings.redpanda_acks,
            "security.protocol": self._settings.redpanda_security_protocol,
        }

        if (
            self._settings.redpanda_sasl_mechanism
            and self._settings.redpanda_sasl_username
            and self._settings.redpanda_sasl_password
        ):
            config["sasl.mechanism"] = self._settings.redpanda_sasl_mechanism
            config["sasl.username"] = self._settings.redpanda_sasl_username
            config["sasl.password"] = self._settings.redpanda_sasl_password

        return Producer(config)

    def publish(
        self,
        cloud_event: BaseModel,
        *,
        correlation_id: str,
        event_id: str,
        event_type: str,
        partition_key: str,
    ) -> PublishResult:
        if self._is_circuit_open():
            raise CircuitBreakerOpenError("Circuit breaker is open")

        max_retries = self._settings.publish_max_retries
        timeout_seconds = self._settings.publish_timeout_seconds

        start = perf_counter()
        last_error: Exception | None = None

        headers = [
            ("correlation_id", correlation_id.encode("utf-8")),
            ("event_id", event_id.encode("utf-8")),
            ("event_type", event_type.encode("utf-8")),
        ]

        payload_bytes = cloud_event.model_dump_json().encode("utf-8")

        for attempt in range(1, max_retries + 1):
            producer: Producer | None = None
            try:
                producer = self._build_producer()
                producer.produce(
                    topic=self._settings.redpanda_topic,
                    key=partition_key.encode("utf-8"),
                    value=payload_bytes,
                    headers=headers,
                )
                producer.flush(timeout=timeout_seconds)

                self._register_success()
                duration_ms = int((perf_counter() - start) * 1000)
                return PublishResult(
                    stream_target=self._settings.redpanda_topic,
                    attempts=attempt,
                    duration_ms=duration_ms,
                )
            except Exception as error:  # noqa: BLE001
                last_error = error
                self._register_failure()
                if attempt < max_retries:
                    sleep(0.2 * attempt)
            finally:
                if producer is not None:
                    producer.flush(timeout=timeout_seconds)

        raise EventPublishError(f"Failed to publish event to Redpanda: {last_error}")


_redpanda_publisher = RedpandaPublisher()


def get_redpanda_publisher() -> RedpandaPublisher:
    return _redpanda_publisher

