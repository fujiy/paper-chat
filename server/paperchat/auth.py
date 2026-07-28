from __future__ import annotations

import hmac
import secrets
import time
from typing import Annotated

from fastapi import Depends, Header, HTTPException
from pydantic import BaseModel, Field

from .config import Settings, load_settings
from .db import connect, new_id, now, token_hash


class RegisterRequest(BaseModel):
    bootstrap_token: str
    device_id: str = Field(min_length=1, max_length=200)
    device_name: str = Field(min_length=1, max_length=200)


class RefreshRequest(BaseModel):
    refresh_token: str


def _issue(settings: Settings, device_id: str, device_name: str) -> dict[str, object]:
    access = secrets.token_urlsafe(32)
    refresh = secrets.token_urlsafe(48)
    timestamp = int(time.time())
    session_id = new_id()
    with connect(settings.resolved_database_path) as conn:
        conn.execute(
            """
            INSERT INTO device_sessions (
              id, device_id, device_name, access_hash, access_expires_at,
              refresh_hash, refresh_expires_at, created_at, last_used_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                session_id,
                device_id,
                device_name,
                token_hash(access),
                timestamp + settings.access_token_ttl_seconds,
                token_hash(refresh),
                timestamp + settings.refresh_token_ttl_seconds,
                now(),
                now(),
            ),
        )
    return {
        "access_token": access,
        "refresh_token": refresh,
        "token_type": "bearer",
        "expires_in": settings.access_token_ttl_seconds,
        "session_id": session_id,
    }


def register(payload: RegisterRequest, settings: Settings) -> dict[str, object]:
    expected = settings.resolved_bootstrap_token
    if not expected or not hmac.compare_digest(expected, payload.bootstrap_token):
        raise HTTPException(401, "Invalid bootstrap token")
    return _issue(settings, payload.device_id, payload.device_name)


def refresh(payload: RefreshRequest, settings: Settings) -> dict[str, object]:
    timestamp = int(time.time())
    with connect(settings.resolved_database_path) as conn:
        row = conn.execute(
            """
            SELECT * FROM device_sessions
            WHERE refresh_hash = ? AND revoked_at IS NULL AND refresh_expires_at > ?
            """,
            (token_hash(payload.refresh_token), timestamp),
        ).fetchone()
        if not row:
            raise HTTPException(401, "Invalid refresh token")
        conn.execute("UPDATE device_sessions SET revoked_at = ? WHERE id = ?", (now(), row["id"]))
    return _issue(settings, row["device_id"], row["device_name"])


def current_session(
    authorization: str | None = Header(default=None),
    settings: SettingsDependency = None,
) -> dict[str, object]:
    token = (authorization or "").removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(401, "Missing access token", headers={"WWW-Authenticate": "Bearer"})
    with connect(settings.resolved_database_path) as conn:
        row = conn.execute(
            """
            SELECT * FROM device_sessions
            WHERE access_hash = ? AND revoked_at IS NULL AND access_expires_at > ?
            """,
            (token_hash(token), int(time.time())),
        ).fetchone()
        if not row:
            raise HTTPException(401, "Invalid access token")
        conn.execute("UPDATE device_sessions SET last_used_at = ? WHERE id = ?", (now(), row["id"]))
    return dict(row)


SettingsDependency = Annotated[Settings, Depends(load_settings)]
