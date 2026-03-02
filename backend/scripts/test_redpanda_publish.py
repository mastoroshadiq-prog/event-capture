"""Simple Redpanda publish smoke test.

Usage:
  python backend/scripts/test_redpanda_publish.py

Optional args:
  --vin MH4ABCD1234567890
  --event-type vehicle.received
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from confluent_kafka import Producer


def _load_env_file() -> None:
    """Load key=value from backend/.env.redpanda if present."""
    env_path = Path(__file__).resolve().parents[1] / ".env.redpanda"
    if not env_path.exists():
        return

    for line in env_path.read_text(encoding="utf-8").splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key and key not in os.environ:
            os.environ[key] = value


def _require_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ValueError(f"Missing required env: {name}")
    return value


def _build_config() -> tuple[dict[str, str], str]:
    bootstrap = _require_env("REDPANDA_BOOTSTRAP_SERVERS")
    topic = _require_env("REDPANDA_TOPIC")

    protocol = os.getenv("REDPANDA_SECURITY_PROTOCOL", "PLAINTEXT").strip()
    client_id = os.getenv("REDPANDA_CLIENT_ID", "event-capture-smoke-test").strip()
    acks = os.getenv("REDPANDA_ACKS", "all").strip()

    config: dict[str, str] = {
        "bootstrap.servers": bootstrap,
        "security.protocol": protocol,
        "client.id": client_id,
        "acks": acks,
    }

    if protocol.upper().startswith("SASL"):
        mechanism = _require_env("REDPANDA_SASL_MECHANISM")
        username = _require_env("REDPANDA_SASL_USERNAME")
        password = _require_env("REDPANDA_SASL_PASSWORD")
        config["sasl.mechanism"] = mechanism
        config["sasl.username"] = username
        config["sasl.password"] = password

    return config, topic


def _build_sample_event(vin: str, event_type: str) -> dict:
    now = datetime.now(timezone.utc).isoformat()
    event_id = str(uuid4())
    correlation_id = str(uuid4())

    return {
        "specversion": "1.0",
        "id": event_id,
        "source": "urn:test:redpanda:smoke",
        "type": event_type,
        "subject": vin,
        "time": now,
        "datacontenttype": "application/json",
        "tenantid": "tenant-test",
        "warehouseid": "WH-01",
        "operatorid": "operator-test",
        "deviceid": "device-test",
        "correlationid": correlation_id,
        "eventversion": "v1",
        "data": {
            "who": {"operator_id": "operator-test"},
            "what": {
                "vin": vin,
                "shipment_id": "SHIP-TEST-001",
                "raw_scan_value": vin,
            },
            "when_scanned_at": now,
            "when_received_at": now,
            "where": {"warehouse_id": "WH-01"},
            "why": {
                "business_process": "inbound_receipt",
                "reason_code": "apm_delivery",
            },
            "how": {
                "scan_method": "qrcode",
                "app_version": "test",
                "device_id": "device-test",
            },
        },
    }


def _print_permission_hint(*, topic: str) -> None:
    username = os.getenv("REDPANDA_SASL_USERNAME", "<unknown>")
    print("\n[TROUBLESHOOTING] TOPIC_AUTHORIZATION_FAILED")
    print(f"- Principal (username/API key): {username}")
    print(f"- Topic target: {topic}")
    print("- Cek di Redpanda Cloud Console -> Security/Access -> ACLs:")
    print("  1) Allow WRITE untuk principal ke topic tersebut")
    print("  2) Allow DESCRIBE untuk principal ke topic tersebut")
    print("  3) Pastikan nama topic persis sama (case-sensitive)")
    print("- Jika topic belum ada, buat dulu atau berikan izin CREATE topic.")
    print("- Pastikan kredensial SASL yang dipakai memang milik principal itu.")


def main() -> int:
    parser = argparse.ArgumentParser(description="Publish test CloudEvent to Redpanda")
    parser.add_argument("--vin", default="MH4ABCD1234567890")
    parser.add_argument("--event-type", default="vehicle.received")
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable verbose Kafka client debug logs",
    )
    args = parser.parse_args()

    try:
        _load_env_file()
        config, topic = _build_config()
        if args.debug:
            config["debug"] = "security,broker,protocol"
    except ValueError as error:
        print(f"[CONFIG ERROR] {error}")
        return 2

    event = _build_sample_event(vin=args.vin.strip(), event_type=args.event_type.strip())
    payload = json.dumps(event, separators=(",", ":")).encode("utf-8")
    partition_key = event["data"]["what"]["vin"].encode("utf-8")

    producer = Producer(config)
    delivered = {"ok": False, "err": ""}

    def _delivery_report(err, msg) -> None:
        if err is not None:
            delivered["err"] = str(err)
            print(f"[PUBLISH ERROR] {err}")
            return
        delivered["ok"] = True
        print(
            "[PUBLISHED] "
            f"topic={msg.topic()} partition={msg.partition()} offset={msg.offset()}"
        )

    producer.produce(
        topic=topic,
        key=partition_key,
        value=payload,
        headers=[
            ("event_id", event["id"].encode("utf-8")),
            ("event_type", event["type"].encode("utf-8")),
            ("correlation_id", event["correlationid"].encode("utf-8")),
        ],
        on_delivery=_delivery_report,
    )
    producer.flush(timeout=15)

    if not delivered["ok"]:
        print("[FAILED] Message not acknowledged by Redpanda")
        if "TOPIC_AUTHORIZATION_FAILED" in delivered["err"]:
            _print_permission_hint(topic=topic)
        return 1

    print("[SUCCESS] Redpanda smoke test passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

