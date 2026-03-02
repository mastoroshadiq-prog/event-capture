"""Generate access token from Zitadel using client credentials flow.

Usage:
  python backend/scripts/generate_zitadel_token.py

Optional:
  python backend/scripts/generate_zitadel_token.py --scope "events:ingest openid profile"
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin
from urllib.parse import quote_plus
from urllib.request import Request, urlopen


def _load_env_file() -> None:
    env_path = Path(__file__).resolve().parents[1] / ".env.redpanda"
    if not env_path.exists():
        return

    for line in env_path.read_text(encoding="utf-8").splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        if key not in os.environ:
            os.environ[key.strip()] = value.strip()


def _get_required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ValueError(f"Missing required env: {name}")
    return value


def _normalize_base_url(value: str) -> str:
    raw = value.strip()
    if raw.startswith("http://") or raw.startswith("https://"):
        return raw.rstrip("/")
    return f"https://{raw.rstrip('/')}"


def _fetch_json(url: str) -> dict | None:
    request = Request(url, method="GET")
    try:
        with urlopen(request, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception:  # noqa: BLE001
        return None


def _discover_token_endpoint(*, issuer: str, domain: str) -> str:
    explicit = os.getenv("ZITADEL_TOKEN_ENDPOINT", "").strip()
    if explicit:
        return explicit

    issuer_base = _normalize_base_url(issuer)
    domain_base = _normalize_base_url(domain)

    candidates = [
        f"{issuer_base}/.well-known/openid-configuration",
        f"{domain_base}/.well-known/openid-configuration",
    ]

    for metadata_url in candidates:
        metadata = _fetch_json(metadata_url)
        if metadata and isinstance(metadata.get("token_endpoint"), str):
            return str(metadata["token_endpoint"])

    fallback_endpoints = [
        f"{issuer_base}/oauth/v2/token",
        f"{domain_base}/oauth/v2/token",
        f"{issuer_base}/oidc/v1/token",
        f"{domain_base}/oidc/v1/token",
    ]
    return fallback_endpoints[0]


def _to_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _build_scope(user_scope: str, audience: str) -> str:
    scopes = [item for item in user_scope.split(" ") if item]

    if audience.isdigit():
        project_audience_scope = f"urn:zitadel:iam:org:project:id:{audience}:aud"
        if project_audience_scope not in scopes:
            scopes.append(project_audience_scope)

    return " ".join(scopes).strip()


def _decode_if_jwt(token: str) -> dict | None:
    parts = token.split(".")
    if len(parts) != 3:
        return None
    payload_b64 = parts[1]
    padding = "=" * (-len(payload_b64) % 4)
    try:
        import base64

        decoded = base64.urlsafe_b64decode((payload_b64 + padding).encode("utf-8"))
        return json.loads(decoded.decode("utf-8"))
    except Exception:  # noqa: BLE001
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate Zitadel access token")
    parser.add_argument("--scope", default=os.getenv("ZITADEL_SCOPE", "events:ingest"))
    args = parser.parse_args()

    try:
        _load_env_file()
        domain = _get_required("AUTH0_DOMAIN")
        issuer = os.getenv("AUTH0_ISSUER", domain)
        audience = _get_required("AUTH0_AUDIENCE")
        client_id = _get_required("ZITADEL_CLIENT_ID")
        client_secret = _get_required("ZITADEL_CLIENT_SECRET")
        scope = _build_scope((args.scope or "").strip(), audience)
        use_audience_param = _to_bool(os.getenv("ZITADEL_USE_AUDIENCE_PARAM"), default=False)
    except ValueError as error:
        print(f"[CONFIG ERROR] {error}")
        return 2

    token_url = _discover_token_endpoint(issuer=issuer, domain=domain)
    form_items = [
        ("grant_type", "client_credentials"),
        ("client_id", client_id),
        ("client_secret", client_secret),
    ]
    if use_audience_param:
        form_items.append(("audience", audience))
    if scope:
        form_items.append(("scope", scope))

    body = "&".join(f"{quote_plus(k)}={quote_plus(v)}" for k, v in form_items).encode("utf-8")
    request = Request(
        token_url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )

    try:
        with urlopen(request, timeout=20) as response:
            raw_response = response.read().decode("utf-8")
    except HTTPError as error:
        body = error.read().decode("utf-8", errors="ignore")
        print(f"[REQUEST ERROR] HTTP {error.code} {error.reason}")
        print(f"[REQUEST URL] {token_url}")
        if body:
            print(f"[RESPONSE BODY] {body}")
        return 1
    except URLError as error:
        print(f"[REQUEST ERROR] URL error: {error}")
        print(f"[REQUEST URL] {token_url}")
        return 1
    except Exception as error:  # noqa: BLE001
        print(f"[REQUEST ERROR] {error}")
        print(f"[REQUEST URL] {token_url}")
        return 1

    try:
        payload = json.loads(raw_response)
    except json.JSONDecodeError:
        print(f"[PARSE ERROR] Invalid JSON response: {raw_response}")
        return 1

    access_token = payload.get("access_token")
    if not access_token:
        print("[TOKEN ERROR] access_token not found")
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 1

    print("[SUCCESS] Access token generated")
    print("\n=== ACCESS TOKEN ===")
    print(access_token)

    maybe_jwt_payload = _decode_if_jwt(access_token)
    if maybe_jwt_payload is not None:
        print("\n=== JWT PAYLOAD (decoded, unsigned) ===")
        print(json.dumps(maybe_jwt_payload, indent=2, ensure_ascii=False))

    return 0


if __name__ == "__main__":
    sys.exit(main())

