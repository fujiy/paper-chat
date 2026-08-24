from __future__ import annotations

import asyncio
import json
from contextlib import asynccontextmanager
from itertools import count
from typing import Annotated, Literal

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


class ThreadEventBroker:
    """In-process invalidation events for the single PaperChat API instance."""

    def __init__(self) -> None:
        self._subscribers: dict[str, set[asyncio.Queue[int]]] = {}
        self._event_ids = count(1)

    def reset(self) -> None:
        self._subscribers.clear()
        self._event_ids = count(1)

    def subscribe(self, thread_id: str) -> asyncio.Queue[int]:
        queue: asyncio.Queue[int] = asyncio.Queue(maxsize=1)
        self._subscribers.setdefault(thread_id, set()).add(queue)
        return queue

    def unsubscribe(self, thread_id: str, queue: asyncio.Queue[int]) -> None:
        subscribers = self._subscribers.get(thread_id)
        if not subscribers:
            return
        subscribers.discard(queue)
        if not subscribers:
            self._subscribers.pop(thread_id, None)

    def publish(self, thread_id: str) -> None:
        event_id = next(self._event_ids)
        for queue in tuple(self._subscribers.get(thread_id, ())):
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            queue.put_nowait(event_id)


thread_events = ThreadEventBroker()


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = load_settings()
    settings.ensure_dirs()
    init(settings.resolved_database_path)
    thread_events.reset()
    with connect(settings.resolved_database_path) as conn:
        # A process restart interrupts active generators. Make their persisted
        # state usable again instead of leaving a thread permanently locked.
        conn.execute(
            "UPDATE messages SET status = 'failed', updated_at = ? WHERE status = 'streaming'",
            (now(),),
        )
        conn.execute(
            "UPDATE threads SET backend_status = 'ready', updated_at = ? "
            "WHERE backend_status = 'streaming'",
            (now(),),
        )
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
    model: str | None = Field(default=None, min_length=1, max_length=200)
    effort: str | None = Field(default=None, min_length=1, max_length=64)


class StarRequest(BaseModel):
    starred: bool


class SelectionRectRequest(BaseModel):
    page_index: int = Field(ge=0)
    x: float = Field(ge=0, le=1)
    y: float = Field(ge=0, le=1)
    width: float = Field(gt=0, le=1)
    height: float = Field(gt=0, le=1)


class BookmarkRequest(BaseModel):
    kind: Literal["page", "selection"]
    page_index: int = Field(ge=0)
    scroll_offset: float = Field(default=0, ge=0)
    selected_text: str | None = Field(default=None, max_length=20000)
    selection_rects: list[SelectionRectRequest] = Field(default_factory=list, max_length=100)
    note: str | None = Field(default=None, max_length=2000)


class PageViewRequest(BaseModel):
    page_index: int = Field(ge=0)
    active_seconds: float = Field(gt=0, le=90)
    new_visit: bool = False


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
    limit: int = Query(default=40, ge=1, le=50),
    offset: int = Query(default=0, ge=0, le=99),
    evidence_limit: int = Query(default=5, ge=1, le=10),
    caller: str | None = Query(default="paperchat", max_length=100),
):
    return await ZoteroLibrary(settings).search(
        q,
        limit=limit,
        offset=offset,
        evidence_limit=evidence_limit,
        caller=caller,
    )


@app.get("/api/library/papers")
async def library_papers(
    _: Session,
    settings: SettingsDependency,
    limit: int = Query(default=500, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
):
    return await ZoteroLibrary(settings).papers(limit=limit, offset=offset)


@app.get("/api/models")
async def list_models(_: Session, settings: SettingsDependency):
    return {"models": await backend(settings).list_models()}


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
    paper["starred"] = bool(
        conn.execute("SELECT 1 FROM paper_stars WHERE paper_id = ?", (paper_id,)).fetchone()
    )
    return paper


@app.get("/api/papers/recent")
def recent_papers(_: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        rows = conn.execute(
            "SELECT * FROM papers ORDER BY last_opened_at DESC NULLS LAST LIMIT 100"
        ).fetchall()
        result = [as_dict(row) for row in rows]
        starred = {
            row["paper_id"] for row in conn.execute("SELECT paper_id FROM paper_stars").fetchall()
        }
    for paper in result:
        paper["starred"] = paper["id"] in starred
    return result


@app.get("/api/papers/starred")
def starred_papers(_: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        rows = conn.execute(
            """
            SELECT p.* FROM papers p
            JOIN paper_stars s ON s.paper_id = p.id
            ORDER BY s.starred_at DESC
            """
        ).fetchall()
    result = [as_dict(row) for row in rows]
    for paper in result:
        paper["starred"] = True
    return result


@app.patch("/api/papers/{paper_id}/star")
def set_paper_star(
    paper_id: str,
    payload: StarRequest,
    _: Session,
    settings: SettingsDependency,
):
    with connect(settings.resolved_database_path) as conn:
        if not conn.execute("SELECT 1 FROM papers WHERE id = ?", (paper_id,)).fetchone():
            raise HTTPException(404, "Paper not found")
        if payload.starred:
            conn.execute(
                """
                INSERT INTO paper_stars (paper_id, starred_at) VALUES (?, ?)
                ON CONFLICT(paper_id) DO UPDATE SET starred_at=excluded.starred_at
                """,
                (paper_id, now()),
            )
        else:
            conn.execute("DELETE FROM paper_stars WHERE paper_id = ?", (paper_id,))
    return {"starred": payload.starred}


@app.get("/api/papers/{paper_id}/bookmarks")
def list_bookmarks(paper_id: str, _: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        if not conn.execute("SELECT 1 FROM papers WHERE id = ?", (paper_id,)).fetchone():
            raise HTTPException(404, "Paper not found")
        bookmark_rows = conn.execute(
            "SELECT * FROM bookmarks WHERE paper_id = ? ORDER BY page_index, created_at",
            (paper_id,),
        ).fetchall()
        suggestion_rows = conn.execute(
            """
            SELECT v.page_index, v.total_active_seconds, v.visit_count, v.last_viewed_at
            FROM page_views v
            WHERE v.paper_id = ?
              AND (v.total_active_seconds >= 45 OR v.visit_count >= 3)
              AND NOT EXISTS (
                SELECT 1 FROM bookmarks b
                WHERE b.paper_id = v.paper_id AND b.page_index = v.page_index
                  AND b.kind = 'page'
              )
            ORDER BY v.total_active_seconds DESC, v.last_viewed_at DESC
            LIMIT 5
            """,
            (paper_id,),
        ).fetchall()
    return {
        "bookmarks": [as_dict(row) for row in bookmark_rows],
        "suggestions": [dict(row) for row in suggestion_rows],
    }


@app.post("/api/papers/{paper_id}/bookmarks", status_code=201)
def create_bookmark(
    paper_id: str,
    payload: BookmarkRequest,
    _: Session,
    settings: SettingsDependency,
):
    if payload.kind == "selection" and (
        not (payload.selected_text or "").strip() or not payload.selection_rects
    ):
        raise HTTPException(422, "Selection bookmarks require text and coordinates")
    timestamp = now()
    with connect(settings.resolved_database_path) as conn:
        if not conn.execute("SELECT 1 FROM papers WHERE id = ?", (paper_id,)).fetchone():
            raise HTTPException(404, "Paper not found")
        if payload.kind == "page":
            existing = conn.execute(
                "SELECT id FROM bookmarks WHERE paper_id = ? AND page_index = ? AND kind = 'page'",
                (paper_id, payload.page_index),
            ).fetchone()
            bookmark_id = existing["id"] if existing else new_id()
            conn.execute(
                """
                INSERT INTO bookmarks (
                  id, paper_id, kind, page_index, scroll_offset, selected_text,
                  selection_rects_json, note, created_at, updated_at
                ) VALUES (?, ?, 'page', ?, ?, NULL, '[]', ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET scroll_offset=excluded.scroll_offset,
                  note=COALESCE(excluded.note, bookmarks.note), updated_at=excluded.updated_at
                """,
                (
                    bookmark_id,
                    paper_id,
                    payload.page_index,
                    payload.scroll_offset,
                    payload.note,
                    timestamp,
                    timestamp,
                ),
            )
        else:
            bookmark_id = new_id()
            conn.execute(
                """
                INSERT INTO bookmarks (
                  id, paper_id, kind, page_index, scroll_offset, selected_text,
                  selection_rects_json, note, created_at, updated_at
                ) VALUES (?, ?, 'selection', ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    bookmark_id,
                    paper_id,
                    payload.page_index,
                    payload.scroll_offset,
                    payload.selected_text,
                    json.dumps([rect.model_dump() for rect in payload.selection_rects]),
                    payload.note,
                    timestamp,
                    timestamp,
                ),
            )
        row = conn.execute("SELECT * FROM bookmarks WHERE id = ?", (bookmark_id,)).fetchone()
    return as_dict(row)


@app.delete("/api/bookmarks/{bookmark_id}", status_code=204)
def delete_bookmark(bookmark_id: str, _: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        deleted = conn.execute("DELETE FROM bookmarks WHERE id = ?", (bookmark_id,))
        if deleted.rowcount != 1:
            raise HTTPException(404, "Bookmark not found")
    return Response(status_code=204)


@app.post("/api/papers/{paper_id}/page-views")
def record_page_view(
    paper_id: str,
    payload: PageViewRequest,
    _: Session,
    settings: SettingsDependency,
):
    timestamp = now()
    with connect(settings.resolved_database_path) as conn:
        if not conn.execute("SELECT 1 FROM papers WHERE id = ?", (paper_id,)).fetchone():
            raise HTTPException(404, "Paper not found")
        conn.execute(
            """
            INSERT INTO page_views (
              paper_id, page_index, total_active_seconds, visit_count, last_viewed_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(paper_id, page_index) DO UPDATE SET
              total_active_seconds=page_views.total_active_seconds + excluded.total_active_seconds,
              visit_count=page_views.visit_count + excluded.visit_count,
              last_viewed_at=excluded.last_viewed_at
            """,
            (
                paper_id,
                payload.page_index,
                payload.active_seconds,
                int(payload.new_visit),
                timestamp,
            ),
        )
    return {"updated_at": timestamp}


@app.get("/api/chats")
def all_chats(_: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        rows = conn.execute(
            """
            SELECT t.*, p.title AS paper_title, p.authors_json, p.year
            FROM threads t
            JOIN papers p ON p.id = t.paper_id
            ORDER BY t.last_used_at DESC
            LIMIT 500
            """
        ).fetchall()
    return [as_dict(row) for row in rows]


@app.get("/api/papers/{paper_id}")
def get_paper(paper_id: str, session: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        return paper_detail(conn, paper_id, str(session["device_id"]))


@app.get("/api/papers/{paper_id}/text-availability")
async def paper_text_availability(
    paper_id: str,
    _: Session,
    settings: SettingsDependency,
):
    with connect(settings.resolved_database_path) as conn:
        identifier = conn.execute(
            """
            SELECT value FROM paper_identifiers
            WHERE paper_id = ? AND kind = 'zotero' LIMIT 1
            """,
            (paper_id,),
        ).fetchone()
    if not identifier:
        return {"available": False}
    try:
        available = await ZoteroLibrary(settings).text_availability(identifier["value"])
        return {"available": available}
    except Exception:
        return {"available": False}


@app.get("/api/papers/{paper_id}/structure")
async def paper_structure(
    paper_id: str,
    _: Session,
    settings: SettingsDependency,
):
    with connect(settings.resolved_database_path) as conn:
        identifier = conn.execute(
            """
            SELECT value FROM paper_identifiers
            WHERE paper_id = ? AND kind = 'zotero' LIMIT 1
            """,
            (paper_id,),
        ).fetchone()
    if not identifier:
        raise HTTPException(404, "PDF source not found")
    return await ZoteroLibrary(settings).structure(identifier["value"])


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


def sse(event: str, data: dict, event_id: int | None = None) -> str:
    identifier = f"id: {event_id}\n" if event_id is not None else ""
    return f"{identifier}event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


@app.get("/api/threads/{thread_id}/events")
async def message_events(thread_id: str, _: Session, settings: SettingsDependency):
    with connect(settings.resolved_database_path) as conn:
        if not conn.execute("SELECT 1 FROM threads WHERE id = ?", (thread_id,)).fetchone():
            raise HTTPException(404, "Thread not found")

    queue = thread_events.subscribe(thread_id)

    async def generate():
        try:
            # The initial invalidation closes the race between the client's
            # messages request and establishing this subscription.
            yield sse("sync", {"thread_id": thread_id})
            while True:
                try:
                    event_id = await asyncio.wait_for(queue.get(), timeout=20)
                    yield sse("sync", {"thread_id": thread_id}, event_id)
                except TimeoutError:
                    yield ": keep-alive\n\n"
        finally:
            thread_events.unsubscribe(thread_id, queue)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


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
        acquired = conn.execute(
            """
            UPDATE threads SET backend_status = 'streaming', updated_at = ?
            WHERE id = ? AND backend_status = 'ready'
            """,
            (timestamp, thread_id),
        )
        if acquired.rowcount != 1:
            raise HTTPException(409, "Thread is already generating a response")
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
    thread_events.publish(thread_id)
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
        f"Current Zotero attachment key: {identifier['value'] if identifier else 'unknown'}\n"
        f"Current PDF page: {page_number}\nQuestion: {payload.content}"
    )

    async def generate():
        answer = ""
        terminal = False

        def fail_generation() -> None:
            nonlocal terminal
            if terminal:
                return
            terminal = True
            with connect(settings.resolved_database_path) as conn:
                conn.execute(
                    "UPDATE messages SET content = ?, status = 'failed', updated_at = ? "
                    "WHERE id = ?",
                    ("", now(), assistant_id),
                )
                conn.execute(
                    "UPDATE threads SET backend_status = 'ready', updated_at = ? WHERE id = ?",
                    (now(), thread_id),
                )
            thread_events.publish(thread_id)

        try:
            yield sse("message", {"message_id": assistant_id, "user_message_id": user_id})
            async for event in backend(settings).stream(
                prompt, thread["backend_thread_id"], payload.model, payload.effort
            ):
                if event.kind == "thread" and event.backend_thread_id:
                    with connect(settings.resolved_database_path) as conn:
                        conn.execute(
                            "UPDATE threads SET backend_thread_id = ?, updated_at = ? WHERE id = ?",
                            (event.backend_thread_id, now(), thread_id),
                        )
                elif event.kind == "delta":
                    answer += event.text
                    yield sse("delta", {"message_id": assistant_id, "delta": event.text})
                elif event.kind == "answer":
                    answer = event.text
                    yield sse("answer", {"message_id": assistant_id, "content": answer})
                elif event.kind == "progress":
                    yield sse(
                        "progress",
                        {
                            "message_id": assistant_id,
                            "id": event.progress_id,
                            "kind": event.progress_kind,
                            "title": event.progress_title,
                            "detail": event.text,
                            "status": event.progress_status,
                            "operation": event.progress_operation,
                        },
                    )
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
                            """
                            UPDATE threads SET last_used_at = ?, updated_at = ?,
                              backend_status = 'ready' WHERE id = ?
                            """,
                            (now(), now(), thread_id),
                        )
                    terminal = True
                    thread_events.publish(thread_id)
                    yield sse("done", {"message_id": assistant_id})
        except asyncio.CancelledError:
            fail_generation()
            raise
        except Exception as error:
            fail_generation()
            yield sse("error", {"message_id": assistant_id, "detail": str(error)})
        finally:
            fail_generation()

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
