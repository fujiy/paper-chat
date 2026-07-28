from __future__ import annotations

import json
from contextlib import asynccontextmanager
from typing import Annotated

import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .auth import (
    RefreshRequest,
    RegisterRequest,
    SettingsDependency,
    current_session,
    refresh,
    register,
)
from .config import load_settings
from .db import as_dict, connect, init, new_id, now
from .library import ZoteroLibrary
from .llm import backend


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = load_settings()
    settings.ensure_dirs()
    init(settings.resolved_database_path)
    yield


app = FastAPI(title="PaperChat", version="0.1.0", lifespan=lifespan)
Session = Annotated[dict[str, object], Depends(current_session)]
SearchQuery = Annotated[str, Query(min_length=1)]


class ResolvePaperRequest(BaseModel):
    attachment_key: str = Field(min_length=1, max_length=64)


class ThreadRequest(BaseModel):
    title: str = Field(default="Main", min_length=1, max_length=200)


class ReadingStateRequest(BaseModel):
    page_index: int = Field(ge=0)
    scroll_offset: float = 0
    zoom_scale: float = Field(default=1, gt=0)
    display_mode: str = "singlePageContinuous"
    active_thread_id: str | None = None


class MessageRequest(BaseModel):
    content: str = Field(min_length=1, max_length=20000)
    current_page_index: int = Field(default=0, ge=0)
    selected_text: str | None = Field(default=None, max_length=20000)
    client_request_id: str = Field(min_length=1, max_length=200)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/api/auth/register")
def auth_register(payload: RegisterRequest, settings: SettingsDependency):
    return register(payload, settings)


@app.post("/api/auth/refresh")
def auth_refresh(payload: RefreshRequest, settings: SettingsDependency):
    return refresh(payload, settings)


@app.get("/api/sessions")
def sessions(_: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        rows = conn.execute(
            """
            SELECT id, device_id, device_name, created_at, last_used_at, revoked_at
            FROM device_sessions ORDER BY last_used_at DESC
            """
        ).fetchall()
    return [dict(row) for row in rows]


@app.delete("/api/sessions/{session_id}", status_code=204)
def revoke_session(session_id: str, _: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        conn.execute("UPDATE device_sessions SET revoked_at = ? WHERE id = ?", (now(), session_id))
    return Response(status_code=204)


@app.get("/api/library/search")
async def search_library(
    q: SearchQuery,
    _: Session,
    settings: SettingsDependency,
):
    return await ZoteroLibrary(settings).search(q)


@app.post("/api/papers/resolve")
async def resolve_paper(
    payload: ResolvePaperRequest,
    _: Session,
    settings: SettingsDependency,
):
    metadata = await ZoteroLibrary(settings).metadata(payload.attachment_key)
    identifier = (
        "zotero",
        metadata.get("library_type"),
        str(metadata.get("library_id") or ""),
        metadata["attachment_key"],
    )
    timestamp = now()
    with connect(settings.resolved_database_path) as conn:
        row = conn.execute(
            """
            SELECT p.* FROM papers p JOIN paper_identifiers i ON i.paper_id = p.id
            WHERE i.kind = ? AND i.library_type = ? AND i.library_id = ? AND i.value = ?
            """,
            identifier,
        ).fetchone()
        if row:
            paper_id = row["id"]
            conn.execute(
                "UPDATE papers SET title = ?, authors_json = ?, year = ?, updated_at = ?, "
                "last_opened_at = ? WHERE id = ?",
                (
                    metadata.get("title") or metadata["filename"],
                    json.dumps(metadata.get("creators") or []),
                    metadata.get("year"),
                    timestamp,
                    timestamp,
                    paper_id,
                ),
            )
        else:
            paper_id = new_id()
            conn.execute(
                """
                INSERT INTO papers
                  (id, title, authors_json, year, created_at, updated_at, last_opened_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    paper_id,
                    metadata.get("title") or metadata["filename"],
                    json.dumps(metadata.get("creators") or []),
                    metadata.get("year"),
                    timestamp,
                    timestamp,
                    timestamp,
                ),
            )
            conn.execute(
                """
                INSERT INTO paper_identifiers
                  (paper_id, kind, library_type, library_id, value, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (paper_id, *identifier, timestamp),
            )
        if metadata.get("parent_item_key"):
            conn.execute(
                """
                INSERT OR IGNORE INTO paper_identifiers
                  (paper_id, kind, library_type, library_id, value, created_at)
                VALUES (?, 'zotero_item', ?, ?, ?, ?)
                """,
                (
                    paper_id,
                    metadata.get("library_type"),
                    str(metadata.get("library_id") or ""),
                    metadata["parent_item_key"],
                    timestamp,
                ),
            )
        result = paper_detail(conn, paper_id, str(_["device_id"]))
    return result


def paper_detail(conn, paper_id: str, device_id: str) -> dict:
    paper = as_dict(conn.execute("SELECT * FROM papers WHERE id = ?", (paper_id,)).fetchone())
    if not paper:
        raise HTTPException(404, "Paper not found")
    paper["identifiers"] = [
        dict(row)
        for row in conn.execute(
            "SELECT kind, library_type, library_id, value FROM paper_identifiers WHERE paper_id = ?",
            (paper_id,),
        )
    ]
    paper["reading_state"] = as_dict(
        conn.execute(
            "SELECT * FROM reading_states WHERE paper_id = ? AND device_id = ?",
            (paper_id, device_id),
        ).fetchone()
    )
    return paper


@app.get("/api/papers/recent")
def recent_papers(_: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        rows = conn.execute(
            "SELECT * FROM papers ORDER BY last_opened_at DESC NULLS LAST LIMIT 100"
        ).fetchall()
    return [as_dict(row) for row in rows]


@app.get("/api/papers/{paper_id}")
def get_paper(paper_id: str, session: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        return paper_detail(conn, paper_id, str(session["device_id"]))


@app.patch("/api/papers/{paper_id}/reading-state")
def save_reading_state(
    paper_id: str,
    payload: ReadingStateRequest,
    session: Session,
    settings: SettingsDependency,
):
    timestamp = now()
    with connect(settings.resolved_database_path) as conn:
        conn.execute(
            """
            INSERT INTO reading_states (
              paper_id, device_id, page_index, scroll_offset, zoom_scale,
              display_mode, active_thread_id, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(paper_id, device_id) DO UPDATE SET
              page_index=excluded.page_index, scroll_offset=excluded.scroll_offset,
              zoom_scale=excluded.zoom_scale, display_mode=excluded.display_mode,
              active_thread_id=excluded.active_thread_id, updated_at=excluded.updated_at
            """,
            (
                paper_id,
                session["device_id"],
                payload.page_index,
                payload.scroll_offset,
                payload.zoom_scale,
                payload.display_mode,
                payload.active_thread_id,
                timestamp,
            ),
        )
        conn.execute(
            "UPDATE papers SET last_opened_at = ?, updated_at = ? WHERE id = ?",
            (timestamp, timestamp, paper_id),
        )
    return {"updated_at": timestamp}


@app.get("/api/papers/{paper_id}/threads")
def list_threads(paper_id: str, _: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        rows = conn.execute(
            "SELECT * FROM threads WHERE paper_id = ? ORDER BY last_used_at DESC", (paper_id,)
        ).fetchall()
    return [dict(row) for row in rows]


@app.post("/api/papers/{paper_id}/threads", status_code=201)
def create_thread(
    paper_id: str,
    payload: ThreadRequest,
    _: Session,
    settings: SettingsDependency,
):
    timestamp, thread_id = now(), new_id()
    with connect(settings.resolved_database_path) as conn:
        if not conn.execute("SELECT 1 FROM papers WHERE id = ?", (paper_id,)).fetchone():
            raise HTTPException(404, "Paper not found")
        primary = not conn.execute(
            "SELECT 1 FROM threads WHERE paper_id = ?", (paper_id,)
        ).fetchone()
        conn.execute(
            """
            INSERT INTO threads (
              id, paper_id, title, backend_type, is_primary,
              last_used_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                thread_id,
                paper_id,
                payload.title,
                settings.llm_backend,
                int(primary),
                timestamp,
                timestamp,
                timestamp,
            ),
        )
        row = conn.execute("SELECT * FROM threads WHERE id = ?", (thread_id,)).fetchone()
    return dict(row)


@app.get("/api/threads/{thread_id}/messages")
def messages(thread_id: str, _: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        rows = conn.execute(
            "SELECT * FROM messages WHERE thread_id = ? ORDER BY created_at", (thread_id,)
        ).fetchall()
    return [as_dict(row) for row in rows]


def sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


@app.post("/api/threads/{thread_id}/messages")
async def send_message(
    thread_id: str,
    payload: MessageRequest,
    _: Session,
    settings: SettingsDependency,
):
    timestamp, user_id, assistant_id = now(), new_id(), new_id()
    with connect(settings.resolved_database_path) as conn:
        thread = conn.execute("SELECT * FROM threads WHERE id = ?", (thread_id,)).fetchone()
        if not thread:
            raise HTTPException(404, "Thread not found")
        existing = conn.execute(
            "SELECT * FROM messages WHERE thread_id = ? AND client_request_id = ?",
            (thread_id, payload.client_request_id),
        ).fetchone()
        if existing:
            raise HTTPException(409, "client_request_id already used")
        identifier = conn.execute(
            """
            SELECT value FROM paper_identifiers
            WHERE paper_id = ? AND kind = 'zotero' LIMIT 1
            """,
            (thread["paper_id"],),
        ).fetchone()
        conn.execute(
            """
            INSERT INTO messages (
              id, thread_id, role, content, page_refs_json, selected_text,
              client_request_id, status, created_at, updated_at
            ) VALUES (?, ?, 'user', ?, ?, ?, ?, 'completed', ?, ?)
            """,
            (
                user_id,
                thread_id,
                payload.content,
                json.dumps([{"page_index": payload.current_page_index}]),
                payload.selected_text,
                payload.client_request_id,
                timestamp,
                timestamp,
            ),
        )
        conn.execute(
            """
            INSERT INTO messages (
              id, thread_id, role, content, page_refs_json, status, created_at, updated_at
            ) VALUES (?, ?, 'assistant', '', '[]', 'streaming', ?, ?)
            """,
            (assistant_id, thread_id, timestamp, timestamp),
        )
    page_number = payload.current_page_index + 1
    context = ""
    if identifier:
        try:
            page_data = await ZoteroLibrary(settings).pages(
                identifier["value"], max(1, page_number - 2), page_number + 2
            )
            context = str(page_data.get("text") or "")
        except Exception:
            context = ""
    prompt = (
        f'<paper_context pages="{max(1, page_number - 2)}-{page_number + 2}">\n'
        f"{context}\n</paper_context>\n"
        f"<selected_text>{payload.selected_text or ''}</selected_text>\n"
        f"Current PDF page: {page_number}\nQuestion: {payload.content}"
    )

    async def generate():
        answer = ""
        try:
            yield sse("message", {"message_id": assistant_id, "user_message_id": user_id})
            async for event in backend(settings).stream(prompt, thread["backend_thread_id"]):
                if event.kind == "thread" and event.backend_thread_id:
                    with connect(settings.resolved_database_path) as conn:
                        conn.execute(
                            "UPDATE threads SET backend_thread_id = ?, updated_at = ? WHERE id = ?",
                            (event.backend_thread_id, now(), thread_id),
                        )
                elif event.kind == "delta":
                    answer += event.text
                    yield sse("delta", {"message_id": assistant_id, "delta": event.text})
                elif event.kind == "done":
                    with connect(settings.resolved_database_path) as conn:
                        conn.execute(
                            """
                            UPDATE messages SET content = ?, status = 'completed',
                              backend_turn_id = ?, updated_at = ? WHERE id = ?
                            """,
                            (answer, event.backend_turn_id, now(), assistant_id),
                        )
                        conn.execute(
                            "UPDATE threads SET last_used_at = ?, updated_at = ? WHERE id = ?",
                            (now(), now(), thread_id),
                        )
                    yield sse("done", {"message_id": assistant_id})
        except Exception as error:
            with connect(settings.resolved_database_path) as conn:
                conn.execute(
                    "UPDATE messages SET content = ?, status = 'failed', updated_at = ? WHERE id = ?",
                    (answer, now(), assistant_id),
                )
            yield sse("error", {"message_id": assistant_id, "detail": str(error)})

    return StreamingResponse(generate(), media_type="text/event-stream")


@app.get("/api/papers/{paper_id}/pdf")
async def paper_pdf(
    paper_id: str,
    _: Session,
    settings: SettingsDependency,
    range_header: str | None = Header(default=None, alias="Range"),
):
    with connect(settings.resolved_database_path) as conn:
        identifier = conn.execute(
            "SELECT value FROM paper_identifiers WHERE paper_id = ? AND kind = 'zotero' LIMIT 1",
            (paper_id,),
        ).fetchone()
    if not identifier:
        raise HTTPException(404, "PDF source not found")
    status, headers, content = await ZoteroLibrary(settings).pdf(identifier["value"], range_header)
    allowed = {
        key: value
        for key, value in headers.items()
        if key.lower()
        in {"content-type", "content-length", "content-range", "accept-ranges", "etag"}
    }
    return Response(content, status_code=status, headers=allowed, media_type="application/pdf")


def run() -> None:
    settings = load_settings()
    uvicorn.run(app, host=settings.http_host, port=settings.http_port)
