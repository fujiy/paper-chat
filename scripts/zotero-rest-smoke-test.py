#!/usr/bin/env python3
"""Run inside the Zotero app container; never print credentials or library content."""

from __future__ import annotations

import re
import sys
import time

import httpx
from zotero_mcp.access_store import database, digest
from zotero_mcp.auth import ADMIN_COOKIE_NAME, create_session_cookie, ensure_admin_secrets
from zotero_mcp.config import load_settings
from zotero_mcp.db import connect

settings = load_settings()
secret = ensure_admin_secrets(settings).session_secret
cookie = create_session_cookie(secret, 300)
csrf = digest("access-management:" + cookie)
base_url = (
    settings.public_base_url.rstrip("/").removesuffix("/mcp")
    if "--public" in sys.argv
    else "http://127.0.0.1:8000"
)
client = httpx.Client(
    base_url=base_url,
    timeout=45,
    follow_redirects=False,
    headers={"User-Agent": "zotero-library-client/1.0"},
)
assert client.get("/health").status_code == 200
assert client.get("/api/v1/library").status_code == 401
assert client.get("/mcp").status_code == 401
spec = client.get("/api/v1/openapi.json")
assert spec.status_code == 200 and "/api/v1/items" in spec.json()["paths"]
client.cookies.set(ADMIN_COOKIE_NAME, cookie)
assert client.get("/admin/access").status_code == 200
assert client.post("/admin/access/tokens", data={"name": "invalid"}).status_code == 403
created = client.post(
    "/admin/access/tokens",
    data={
        "csrf": csrf,
        "name": "Deployment verification",
        "days": 1,
    },
)
assert created.status_code == 201
match = re.search(r"zml_[\w-]+", created.text)
assert match is not None
token = match[0]
with database(settings) as conn:
    token_id = conn.execute(
        "SELECT id FROM api_tokens WHERE token_hash=?", (digest(token),)
    ).fetchone()[0]
client.headers["Authorization"] = "Bearer " + token
try:
    assert client.get("/api/v1/library").status_code == 200
    search = client.get("/api/v1/search", params={"q": "technology", "limit": 2})
    assert search.status_code == 200 and "papers" in search.json()
    upstream = client.get("/api/v1/items", params={"limit": 1})
    assert upstream.status_code == 200, f"upstream HTTP {upstream.status_code}"
    assert isinstance(upstream.json(), list)
    assert client.get("/api/v1/users/999/items").status_code == 404
    assert client.post("/api/v1/items").status_code == 405
    with connect(settings.resolved_database_path) as conn:
        row = conn.execute(
            "SELECT a.key FROM attachments a WHERE a.file_path IS NOT NULL "
            "AND EXISTS(SELECT 1 FROM pages p WHERE p.attachment_key=a.key) LIMIT 1"
        ).fetchone()
    assert row is not None, "no cached/indexed attachment available"
    key = row[0]
    assert client.get(f"/api/v1/attachments/{key}").status_code == 200
    assert client.get(f"/api/v1/attachments/{key}/pages?start=1&end=1").status_code == 200
    pdf = client.get(f"/api/v1/attachments/{key}/pdf", headers={"Range": "bytes=0-63"})
    assert pdf.status_code == 206 and len(pdf.content) == 64
    assert client.get(f"/api/v1/attachments/{key}/structure").status_code in (200, 202)
    print("REST health/auth/UI/search/upstream/pages/PDF Range/structure: passed")
finally:
    response = client.post(f"/admin/access/tokens/{token_id}/revoke", data={"csrf": csrf})
    # Ensure the temporary token cannot survive a failed HTTP cleanup.
    with database(settings) as conn:
        conn.execute("UPDATE api_tokens SET revoked_at=? WHERE id=?", (int(time.time()), token_id))
    assert response.status_code == 303
    assert client.get("/api/v1/library").status_code == 401
    print("Temporary API token revoked: passed")

mcp_token = settings.resolved_mcp_service_token()
assert mcp_token
mcp = client.post(
    "/mcp",
    headers={
        "Authorization": "Bearer " + mcp_token,
        "Accept": "application/json, text/event-stream",
    },
    json={
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "deployment-smoke", "version": "1.0"},
        },
    },
)
assert mcp.status_code == 200
print("Existing authenticated MCP initialization: passed")
page = client.get("/admin/access")
assert page.status_code == 200 and 'name="api_key"' in page.text
assert "Zotero OAuth" not in page.text
assert client.post("/admin/access/zotero/key", data={"api_key": "invalid"}).status_code == 403
for path in ("application", "connect"):
    assert client.post("/admin/access/zotero/" + path, data={"csrf": csrf}).status_code == 404
assert client.get("/admin/access/zotero/callback").status_code == 404
print("API-key setup UI and retired outbound OAuth routes: passed")
