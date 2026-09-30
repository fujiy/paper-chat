#!/usr/bin/env python3
"""Exercise the deployed PaperChat API without printing credentials."""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

base_url = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000"
attachment_key = sys.argv[2] if len(sys.argv) > 2 else "26MBZCQC"


def request(
    method: str,
    path: str,
    *,
    token: str | None = None,
    payload: dict | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], bytes]:
    body = json.dumps(payload).encode() if payload is not None else None
    request_headers = {"Content-Type": "application/json"}
    if token:
        request_headers["Authorization"] = f"Bearer {token}"
    request_headers.update(headers or {})
    req = urllib.request.Request(
        f"{base_url}{path}", data=body, method=method, headers=request_headers
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


def expect(status: int, expected: int, body: bytes) -> None:
    if status != expected:
        raise RuntimeError(f"expected HTTP {expected}, got {status}: {body[:500]!r}")


with open("/run/secrets/paperchat_bootstrap_token", encoding="utf-8") as secret_file:
    bootstrap_token = secret_file.read().strip()
status, _, body = request(
    "POST",
    "/api/auth/register",
    payload={
        "bootstrap_token": bootstrap_token,
        "device_id": f"smoke-{uuid.uuid4()}",
        "device_name": "Deployment smoke test",
    },
)
expect(status, 200, body)
tokens = json.loads(body)
access_token = tokens["access_token"]

query = urllib.parse.urlencode({"q": "technology"})
status, _, body = request("GET", f"/api/library/search?{query}", token=access_token)
expect(status, 200, body)

status, _, body = request(
    "POST",
    "/api/papers/resolve",
    token=access_token,
    payload={"attachment_key": attachment_key},
)
expect(status, 200, body)
paper = json.loads(body)

status, _, body = request(
    "POST",
    f"/api/papers/{paper['id']}/bookmarks",
    token=access_token,
    payload={
        "kind": "selection",
        "page_index": 2,
        "page_position": 0.37,
        "selected_text": "Deployment bookmark smoke test",
        "selection_rects": [
            {"page_index": 2, "x": 0.1, "y": 0.5, "width": 0.2, "height": 0.05}
        ],
    },
)
expect(status, 201, body)
bookmark = json.loads(body)
if bookmark.get("page_position") != 0.37:
    raise RuntimeError("bookmark page position was not persisted")
status, _, body = request(
    "GET", f"/api/papers/{paper['id']}/bookmarks", token=access_token
)
expect(status, 200, body)
bookmarks = json.loads(body)["bookmarks"]
if not any(item["id"] == bookmark["id"] for item in bookmarks):
    raise RuntimeError("persisted bookmark was not returned")
status, _, body = request(
    "DELETE", f"/api/bookmarks/{bookmark['id']}", token=access_token
)
expect(status, 204, body)

status, _, body = request(
    "GET", f"/api/papers/{paper['id']}/structure", token=access_token
)
expect(status, 200, body)
structure = json.loads(body)
if structure.get("status") not in {"pending", "processing", "ready"}:
    raise RuntimeError(f"unexpected structure status: {structure.get('status')!r}")

status, _, body = request(
    "POST",
    f"/api/papers/{paper['id']}/threads",
    token=access_token,
    payload={"title": "Smoke test"},
)
expect(status, 201, body)
thread = json.loads(body)

status, _, body = request(
    "PATCH",
    f"/api/papers/{paper['id']}/reading-state",
    token=access_token,
    payload={"page_index": 2, "active_thread_id": thread["id"]},
)
expect(status, 200, body)

status, headers, pdf_chunk = request(
    "GET",
    f"/api/papers/{paper['id']}/pdf",
    token=access_token,
    headers={"Range": "bytes=0-1023"},
)
expect(status, 206, pdf_chunk)
if len(pdf_chunk) != 1024 or "content-range" not in {
    key.lower() for key in headers
}:
    raise RuntimeError("PDF range response was incomplete")

status, _, chat = request(
    "POST",
    f"/api/threads/{thread['id']}/messages",
    token=access_token,
    payload={
        "content": "Summarize the nearby evidence.",
        "current_page_index": 2,
        "selected_text": None,
        "client_request_id": str(uuid.uuid4()),
    },
)
expect(status, 200, chat)
events = [
    line.removeprefix("event: ")
    for line in chat.decode().splitlines()
    if line.startswith("event: ")
]
if not events or events[0] != "message" or events[-1] != "done":
    raise RuntimeError(f"unexpected SSE events: {events}")

status, _, body = request(
    "GET", f"/api/threads/{thread['id']}/messages", token=access_token
)
expect(status, 200, body)
messages = json.loads(body)
if [message["role"] for message in messages] != ["user", "assistant"]:
    raise RuntimeError("persisted chat messages were incomplete")

status, _, body = request(
    "POST",
    "/api/auth/refresh",
    payload={"refresh_token": tokens["refresh_token"]},
)
expect(status, 200, body)
refreshed_tokens = json.loads(body)
status, _, body = request(
    "POST",
    "/api/auth/refresh",
    payload={"refresh_token": tokens["refresh_token"]},
)
expect(status, 401, body)

status, _, body = request(
    "DELETE",
    f"/api/sessions/{refreshed_tokens['session_id']}",
    token=refreshed_tokens["access_token"],
)
expect(status, 204, body)
status, _, body = request(
    "GET", "/api/papers/recent", token=refreshed_tokens["access_token"]
)
expect(status, 401, body)

print(
    json.dumps(
        {
            "status": "ok",
            "paper_title": paper["title"],
            "bookmark_page_position": bookmark["page_position"],
            "pdf_range_bytes": len(pdf_chunk),
            "structure_status": structure["status"],
            "sse_events": events,
            "persisted_messages": len(messages),
            "refresh_rotation": "ok",
            "session_revocation": "ok",
        },
        ensure_ascii=False,
    )
)
