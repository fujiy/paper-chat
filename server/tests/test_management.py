import json
import sqlite3

import httpx
import pytest
from fastapi.testclient import TestClient
from paperchat.config import Settings
from paperchat.db import SCHEMA, connect, init, now
from paperchat.llm import CodexBackend, LLMEvent, RemoteBackend, backend
from paperchat.runner import app as runner_app
from test_api import client_for


def test_management_chat_persistence_and_server_owned_mode(tmp_path, monkeypatch):
    calls = []

    class Backend:
        async def stream(self, prompt, thread_id, model, effort, mode):
            calls.append((prompt, thread_id, mode))
            yield LLMEvent("thread", backend_thread_id="management-backend")
            yield LLMEvent("answer", text="Setup complete")
            yield LLMEvent("done", backend_turn_id="turn-1")

    monkeypatch.setattr("paperchat.main.backend", lambda _: Backend())
    with client_for(tmp_path, monkeypatch) as client:
        assert client.post("/api/chats", json={"title": "Setup"}).status_code == 401
        tokens = client.post(
            "/api/auth/register",
            json={
                "bootstrap_token": "bootstrap-secret",
                "device_id": "admin-test",
                "device_name": "test",
            },
        ).json()
        headers = {"Authorization": f"Bearer {tokens['access_token']}"}
        chat = client.post("/api/chats", json={"title": "Setup"}, headers=headers)
        assert chat.status_code == 201
        thread = chat.json()
        assert thread["paper_id"] is None
        for request_id in ("first", "second"):
            result = client.post(
                f"/api/threads/{thread['id']}/messages",
                headers=headers,
                json={
                    "content": "Install the requested tools",
                    "client_request_id": request_id,
                    "selected_text": "must not leak into a management chat",
                    "current_page_index": 50,
                },
            )
            assert "event: done" in result.text
        messages = client.get(f"/api/threads/{thread['id']}/messages", headers=headers).json()
        assert len(messages) == 4
        assert messages[0]["page_refs"] == []
        assert messages[0]["selected_text"] is None
        assert calls == [
            ("Install the requested tools", None, "management"),
            ("Install the requested tools", "management-backend", "management"),
        ]
        assert client.get("/api/chats", headers=headers).json() == []
        overview = client.get("/api/chats?include_management=true", headers=headers).json()[0]
        assert overview["paper_id"] is None and overview["authors"] == []
        assert (
            client.get(f"/api/threads/{thread['id']}", headers=headers).json()["backend_thread_id"]
            == "management-backend"
        )
        paper = client.post(
            "/api/papers/resolve", json={"attachment_key": "ABCD1234"}, headers=headers
        ).json()
        paper_thread = client.post(
            f"/api/papers/{paper['id']}/threads", json={}, headers=headers
        ).json()
        client.post(
            f"/api/threads/{paper_thread['id']}/messages",
            headers=headers,
            json={
                "content": "Read this",
                "client_request_id": "paper",
                "mode": "management",
            },
        )
        assert calls[-1][2] == "paper"
    # A new API process can reopen the same management conversation.
    with client_for(tmp_path, monkeypatch) as client:
        assert client.get(f"/api/threads/{thread['id']}", headers=headers).status_code == 200


def test_nullable_paper_migration_preserves_history_and_foreign_keys(tmp_path):
    path = tmp_path / "legacy.sqlite3"
    with sqlite3.connect(path) as conn:
        conn.executescript(
            SCHEMA.replace(
                "id TEXT PRIMARY KEY, paper_id TEXT, title TEXT NOT NULL,",
                "id TEXT PRIMARY KEY, paper_id TEXT NOT NULL, title TEXT NOT NULL,",
            )
        )
        timestamp = now()
        conn.execute(
            "INSERT INTO papers (id,title,created_at,updated_at) VALUES ('p','P',?,?)",
            (timestamp, timestamp),
        )
        conn.execute(
            """INSERT INTO threads
            (id,paper_id,title,backend_type,backend_thread_id,last_used_at,created_at,updated_at)
            VALUES ('t','p','T','codex','backend',?,?,?)""",
            (timestamp,) * 3,
        )
        conn.execute(
            """INSERT INTO messages
            (id,thread_id,role,content,status,created_at,updated_at)
            VALUES ('m','t','user','Hello','completed',?,?)""",
            (timestamp,) * 2,
        )
    init(path)
    init(path)
    with connect(path) as conn:
        assert conn.execute("SELECT content FROM messages").fetchone()[0] == "Hello"
        assert conn.execute("SELECT backend_thread_id FROM threads").fetchone()[0] == "backend"
        assert not conn.execute("PRAGMA foreign_key_check").fetchall()
        conn.execute("UPDATE threads SET paper_id=NULL WHERE id='t'")
        conn.execute("DELETE FROM threads WHERE id='t'")
        assert not conn.execute("SELECT * FROM messages").fetchall()


def test_bookmark_offset_migration_to_page_positions(tmp_path):
    path = tmp_path / "legacy-bookmarks.sqlite3"
    legacy_schema = SCHEMA.replace(
        "page_position REAL NOT NULL CHECK(page_position >= 0 AND page_position <= 1),",
        "scroll_offset REAL NOT NULL DEFAULT 0,",
    )
    with sqlite3.connect(path) as conn:
        conn.executescript(legacy_schema)
        timestamp = now()
        conn.execute(
            "INSERT INTO papers (id,title,created_at,updated_at) VALUES ('p','P',?,?)",
            (timestamp, timestamp),
        )
        conn.execute(
            """INSERT INTO bookmarks
            (id,paper_id,kind,page_index,scroll_offset,created_at,updated_at)
            VALUES ('page','p','page',8,3520,?,?)""",
            (timestamp, timestamp),
        )
        conn.execute(
            """INSERT INTO bookmarks
            (id,paper_id,kind,page_index,scroll_offset,selected_text,
             selection_rects_json,created_at,updated_at)
            VALUES ('selection','p','selection',8,3520,'anchor',?,?,?)""",
            (
                json.dumps([{
                    "page_index": 8,
                    "x": 0.1,
                    "y": 0.25,
                    "width": 0.3,
                    "height": 0.2,
                }]),
                timestamp,
                timestamp,
            ),
        )

    init(path)
    init(path)
    with connect(path) as conn:
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(bookmarks)")}
        assert "scroll_offset" not in columns
        assert conn.execute(
            "SELECT page_position FROM bookmarks WHERE id='page'"
        ).fetchone()[0] == 0
        assert conn.execute(
            "SELECT page_position FROM bookmarks WHERE id='selection'"
        ).fetchone()[0] == pytest.approx(0.65)
        assert not conn.execute("PRAGMA foreign_key_check").fetchall()


def test_runner_authorization_and_stream(tmp_path, monkeypatch):
    settings = Settings(
        CODEX_RUNNER_TOKEN="runner-only",
        CODEX_HOME_DIR=tmp_path / "home",
        CODEX_WORKSPACE=tmp_path / "workspace",
        _env_file=None,
    )
    monkeypatch.setattr("paperchat.runner.load_settings", lambda: settings)
    seen = []

    async def stream(self, **kwargs):
        seen.append(kwargs)
        yield LLMEvent("answer", text="ready")
        yield LLMEvent("done")

    monkeypatch.setattr(CodexBackend, "stream", stream)
    with TestClient(runner_app) as client:
        assert client.get("/models").status_code == 401
        assert client.post("/turns", json={"prompt": "hello"}).status_code == 401
        response = client.post(
            "/turns",
            headers={"Authorization": "Bearer runner-only"},
            json={"prompt": "hello", "mode": "management"},
        )
        assert [json.loads(line)["kind"] for line in response.text.splitlines()] == [
            "answer",
            "done",
        ]
        assert seen[0]["mode"] == "management"
        assert (
            client.post(
                "/turns",
                headers={"Authorization": "Bearer runner-only"},
                json={"prompt": "hello", "mode": "arbitrary"},
            ).status_code
            == 422
        )


@pytest.mark.asyncio
async def test_remote_backend_forwards_mode_and_reports_stream_failure(tmp_path, monkeypatch):
    settings = Settings(
        LLM_BACKEND="codex",
        CODEX_RUNNER_URL="http://runner",
        CODEX_RUNNER_TOKEN="runner-only",
        DATA_DIR=tmp_path,
        _env_file=None,
    )
    assert isinstance(backend(settings), RemoteBackend)

    def handle(request):
        assert request.headers["authorization"] == "Bearer runner-only"
        assert json.loads(request.content)["mode"] == "management"
        return httpx.Response(
            200, text='{"kind":"answer","text":"hello"}\n{"error":"runner failed"}\n'
        )

    transport = httpx.MockTransport(handle)
    original = httpx.AsyncClient
    monkeypatch.setattr(
        "paperchat.llm.httpx.AsyncClient", lambda **kwargs: original(transport=transport, **kwargs)
    )
    events = []
    with pytest.raises(RuntimeError, match="runner failed"):
        async for event in backend(settings).stream("install", mode="management"):
            events.append(event)
    assert events[0].text == "hello"


def test_management_permissions_and_mcp_configuration_are_generic(tmp_path):
    settings = Settings(CODEX_HOME_DIR=tmp_path, _env_file=None)
    codex = CodexBackend(settings)
    assert codex.thread_resume_params("t", "management")["sandbox"] == "danger-full-access"
    assert codex.thread_resume_params("t", "paper")["sandbox"] == "read-only"
    assert codex.mcp_config_override().startswith("mcp_servers.zotero_library=")
    assert "$CODEX_HOME/skills" in codex.developer_instructions("management")


def test_container_sandbox_flag_preserves_paper_read_only(tmp_path):
    settings = Settings(CODEX_HOME_DIR=tmp_path, CODEX_LEGACY_LANDLOCK=True, _env_file=None)
    codex = CodexBackend(settings)
    assert "features.use_legacy_landlock=true" in codex.command_args()
    assert codex.thread_resume_params("t")["sandbox"] == "read-only"
    assert codex.thread_resume_params("t", "management")["sandbox"] == "danger-full-access"
