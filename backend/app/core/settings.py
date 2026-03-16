from dataclasses import dataclass
from functools import lru_cache
from os import getenv
from pathlib import Path


_ENV_LOADED = False


def _load_env_files() -> None:
    global _ENV_LOADED
    if _ENV_LOADED:
        return

    base_dir = Path(__file__).resolve().parents[2]  # backend/
    candidates = [
        base_dir / ".env",
        base_dir / ".env.local",
        base_dir / ".env.redpanda",
    ]

    for path in candidates:
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            raw = line.strip()
            if not raw or raw.startswith("#") or "=" not in raw:
                continue
            key, value = raw.split("=", 1)
            key = key.strip()
            value = value.strip()
            if key:
                from os import environ

                # File-based env should be authoritative for this project runtime
                # to avoid stale shell/session variables overriding latest config.
                environ[key] = value

    _ENV_LOADED = True


def _split_csv_env(value: str | None) -> set[str]:
    if not value:
        return set()
    return {item.strip() for item in value.split(",") if item.strip()}


def _get_int_env(name: str, default: int) -> int:
    raw_value = getenv(name)
    if raw_value is None:
        return default
    try:
        return int(raw_value)
    except ValueError:
        return default


def _get_float_env(name: str, default: float) -> float:
    raw_value = getenv(name)
    if raw_value is None:
        return default
    try:
        return float(raw_value)
    except ValueError:
        return default


def _get_bool_env(name: str, default: bool) -> bool:
    raw_value = getenv(name)
    if raw_value is None:
        return default
    return raw_value.strip().lower() in {"1", "true", "yes", "on"}


def _get_optional_str_env(name: str, default: str | None = None) -> str | None:
    raw_value = getenv(name)
    if raw_value is None:
        return default
    value = raw_value.strip()
    return value or None


@dataclass(frozen=True)
class Settings:
    auth_disable: bool
    auth_domain: str
    auth_audience: str
    auth_issuer: str
    auth_jwks_url: str | None
    auth_jwt_secret: str | None
    auth_jwt_algorithms: list[str]
    auth_verify_audience: bool
    auth_required_scope: str | None
    auth_required_role: str | None
    auth_supervisor_role: str
    auth_operator_id_claim: str
    auth_device_id_claim: str | None
    auth_enforce_operator_match: bool
    auth_enforce_device_match: bool
    allowed_device_ids: set[str]
    redpanda_bootstrap_servers: str
    redpanda_topic: str
    redpanda_security_protocol: str
    redpanda_sasl_mechanism: str | None
    redpanda_sasl_username: str | None
    redpanda_sasl_password: str | None
    redpanda_client_id: str
    redpanda_acks: str
    publish_max_retries: int
    publish_timeout_seconds: float
    circuit_breaker_failure_threshold: int
    circuit_breaker_reset_seconds: int
    dead_letter_dir: str
    supabase_db_url: str | None


@lru_cache
def get_settings() -> Settings:
    _load_env_files()

    auth0_domain = getenv("AUTH0_DOMAIN", "").strip()
    default_legacy_issuer = f"https://{auth0_domain}/" if auth0_domain else ""

    auth_domain = getenv("AUTH_DOMAIN", auth0_domain).strip()
    auth_issuer = getenv("AUTH_ISSUER", getenv("AUTH0_ISSUER", default_legacy_issuer)).strip()
    auth_audience = getenv("AUTH_AUDIENCE", getenv("AUTH0_AUDIENCE", "")).strip()

    auth_jwks_url = _get_optional_str_env("AUTH_JWKS_URL")
    if auth_jwks_url is None and auth_issuer:
        auth_jwks_url = f"{auth_issuer.rstrip('/')}/.well-known/jwks.json"

    raw_algorithms = getenv("AUTH_JWT_ALGORITHMS", "RS256")
    auth_jwt_algorithms = [item.strip() for item in raw_algorithms.split(",") if item.strip()]
    if not auth_jwt_algorithms:
        auth_jwt_algorithms = ["RS256"]

    return Settings(
        auth_disable=_get_bool_env("AUTH_DISABLE", False),
        auth_domain=auth_domain,
        auth_audience=auth_audience,
        auth_issuer=auth_issuer,
        auth_jwks_url=auth_jwks_url,
        auth_jwt_secret=_get_optional_str_env("AUTH_JWT_SECRET"),
        auth_jwt_algorithms=auth_jwt_algorithms,
        auth_verify_audience=_get_bool_env("AUTH_VERIFY_AUDIENCE", True),
        auth_required_scope=_get_optional_str_env("AUTH_REQUIRED_SCOPE", "events:ingest"),
        auth_required_role=_get_optional_str_env("AUTH_REQUIRED_ROLE", "warehouse_operator"),
        auth_supervisor_role=getenv("AUTH_SUPERVISOR_ROLE", "warehouse_supervisor"),
        auth_operator_id_claim=getenv(
            "AUTH_OPERATOR_ID_CLAIM", "https://event-capture/operator_id"
        ),
        auth_device_id_claim=_get_optional_str_env(
            "AUTH_DEVICE_ID_CLAIM", "https://event-capture/device_id"
        ),
        auth_enforce_operator_match=_get_bool_env("AUTH_ENFORCE_OPERATOR_MATCH", True),
        auth_enforce_device_match=_get_bool_env("AUTH_ENFORCE_DEVICE_MATCH", True),
        allowed_device_ids=_split_csv_env(getenv("AUTH_ALLOWED_DEVICE_IDS")),
        redpanda_bootstrap_servers=getenv("REDPANDA_BOOTSTRAP_SERVERS", ""),
        redpanda_topic=getenv("REDPANDA_TOPIC", "vehicle-events"),
        redpanda_security_protocol=getenv("REDPANDA_SECURITY_PROTOCOL", "PLAINTEXT"),
        redpanda_sasl_mechanism=getenv("REDPANDA_SASL_MECHANISM"),
        redpanda_sasl_username=getenv("REDPANDA_SASL_USERNAME"),
        redpanda_sasl_password=getenv("REDPANDA_SASL_PASSWORD"),
        redpanda_client_id=getenv("REDPANDA_CLIENT_ID", "event-capture-gateway"),
        redpanda_acks=getenv("REDPANDA_ACKS", "all"),
        publish_max_retries=max(1, _get_int_env("PUBLISH_MAX_RETRIES", 3)),
        publish_timeout_seconds=max(1.0, _get_float_env("PUBLISH_TIMEOUT_SECONDS", 5.0)),
        circuit_breaker_failure_threshold=max(
            1, _get_int_env("CIRCUIT_BREAKER_FAILURE_THRESHOLD", 5)
        ),
        circuit_breaker_reset_seconds=max(
            1, _get_int_env("CIRCUIT_BREAKER_RESET_SECONDS", 30)
        ),
        dead_letter_dir=getenv("DEAD_LETTER_DIR", "backend/dead_letter"),
        supabase_db_url=_get_optional_str_env("SUPABASE_DB_URL", _get_optional_str_env("DATABASE_URL")),
    )

