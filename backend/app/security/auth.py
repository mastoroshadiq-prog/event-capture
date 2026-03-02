from collections.abc import Iterable

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import InvalidTokenError, PyJWKClient
from pydantic import BaseModel, Field

from app.core.settings import get_settings


class AuthContext(BaseModel):
    subject: str = Field(min_length=1)
    operator_id: str = Field(min_length=1)
    device_id: str | None = None
    scopes: set[str] = Field(default_factory=set)
    roles: set[str] = Field(default_factory=set)


bearer_scheme = HTTPBearer(auto_error=False)
_jwks_clients: dict[str, PyJWKClient] = {}


def _get_jwks_client(jwks_url: str) -> PyJWKClient:
    cached_client = _jwks_clients.get(jwks_url)
    if cached_client:
        return cached_client
    client = PyJWKClient(jwks_url)
    _jwks_clients[jwks_url] = client
    return client


def _extract_scopes(payload: dict) -> set[str]:
    scopes: set[str] = set()

    raw_scope = payload.get("scope")
    if isinstance(raw_scope, str):
        scopes.update(scope.strip() for scope in raw_scope.split(" ") if scope.strip())

    raw_permissions = payload.get("permissions")
    if isinstance(raw_permissions, Iterable) and not isinstance(raw_permissions, str):
        scopes.update(
            permission.strip()
            for permission in raw_permissions
            if isinstance(permission, str) and permission.strip()
        )

    return scopes


def _extract_roles(payload: dict, auth_domain: str) -> set[str]:
    roles: set[str] = set()

    raw_roles = payload.get("roles")
    if isinstance(raw_roles, Iterable) and not isinstance(raw_roles, str):
        roles.update(role.strip() for role in raw_roles if isinstance(role, str) and role.strip())

    if auth_domain:
        namespaced_claim = f"https://{auth_domain}/roles"
        raw_namespaced_roles = payload.get(namespaced_claim)
        if isinstance(raw_namespaced_roles, Iterable) and not isinstance(
            raw_namespaced_roles, str
        ):
            roles.update(
                role.strip()
                for role in raw_namespaced_roles
                if isinstance(role, str) and role.strip()
            )

    app_metadata = payload.get("app_metadata")
    if isinstance(app_metadata, dict):
        raw_app_roles = app_metadata.get("roles")
        if isinstance(raw_app_roles, Iterable) and not isinstance(raw_app_roles, str):
            roles.update(
                role.strip()
                for role in raw_app_roles
                if isinstance(role, str) and role.strip()
            )

    user_metadata = payload.get("user_metadata")
    if isinstance(user_metadata, dict):
        raw_user_roles = user_metadata.get("roles")
        if isinstance(raw_user_roles, Iterable) and not isinstance(raw_user_roles, str):
            roles.update(
                role.strip()
                for role in raw_user_roles
                if isinstance(role, str) and role.strip()
            )

    raw_role = payload.get("role")
    if isinstance(raw_role, str) and raw_role.strip():
        roles.add(raw_role.strip())

    return roles


def _decode_jwt(token: str) -> dict:
    settings = get_settings()

    algorithms = settings.auth_jwt_algorithms or ["RS256"]
    jwt_options = {"verify_aud": settings.auth_verify_audience}

    try:
        if settings.auth_jwt_secret:
            decode_kwargs: dict = {
                "algorithms": algorithms,
                "options": jwt_options,
            }
            if settings.auth_verify_audience:
                decode_kwargs["audience"] = settings.auth_audience
            if settings.auth_issuer:
                decode_kwargs["issuer"] = settings.auth_issuer

            return jwt.decode(token, settings.auth_jwt_secret, **decode_kwargs)

        if not settings.auth_jwks_url:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Auth JWKS URL is not configured",
            )

        jwks_client = _get_jwks_client(settings.auth_jwks_url)
        signing_key = jwks_client.get_signing_key_from_jwt(token).key

        decode_kwargs = {
            "algorithms": algorithms,
            "options": jwt_options,
        }
        if settings.auth_verify_audience:
            decode_kwargs["audience"] = settings.auth_audience
        if settings.auth_issuer:
            decode_kwargs["issuer"] = settings.auth_issuer

        return jwt.decode(
            token,
            signing_key,
            **decode_kwargs,
        )
    except InvalidTokenError as error:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid token: {error}",
        ) from error


def get_auth_context(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
) -> AuthContext:
    if credentials is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing bearer token",
        )

    settings = get_settings()
    if settings.auth_verify_audience and not settings.auth_audience:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Auth audience is not configured",
        )

    if not settings.auth_issuer and not settings.auth_jwt_secret:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Auth issuer or shared secret is not configured",
        )

    token = credentials.credentials
    payload = _decode_jwt(token)

    scopes = _extract_scopes(payload)
    roles = _extract_roles(payload, settings.auth_domain)

    if settings.auth_required_scope and settings.auth_required_scope not in scopes:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Missing required scope",
        )

    if settings.auth_required_role and settings.auth_required_role not in roles:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Missing required role",
        )

    subject = str(payload.get("sub", "")).strip()
    operator_claim_value = payload.get(settings.auth_operator_id_claim)
    operator_id = str(operator_claim_value or subject).strip()

    device_id_value = payload.get(settings.auth_device_id_claim) if settings.auth_device_id_claim else None
    device_id = str(device_id_value).strip() if device_id_value else None

    if not subject:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token subject is missing",
        )

    if not operator_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Operator claim is missing",
        )

    return AuthContext(
        subject=subject,
        operator_id=operator_id,
        device_id=device_id,
        scopes=scopes,
        roles=roles,
    )


def enforce_ingest_authorization(
    auth_context: AuthContext,
    *,
    payload_operator_id: str,
    payload_device_id: str,
) -> None:
    settings = get_settings()

    supervisor_role = settings.auth_supervisor_role
    is_supervisor = supervisor_role in auth_context.roles

    if (
        settings.auth_enforce_operator_match
        and auth_context.operator_id != payload_operator_id
        and not is_supervisor
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Operator not authorized for this payload",
        )

    if (
        settings.auth_enforce_device_match
        and auth_context.device_id
        and auth_context.device_id != payload_device_id
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Device claim does not match payload device_id",
        )

    if settings.allowed_device_ids and payload_device_id not in settings.allowed_device_ids:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Device is not registered",
        )

