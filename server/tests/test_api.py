from __future__ import annotations

from fastapi.testclient import TestClient
from paperchat.config import Settings, load_settings
from paperchat.db import connect, now
from paperchat.main import ThreadEventBroker, app


def client_for(tmp_path, monkeypatch) -> TestClient:
    settings = Settings(
        DATA_DIR=tmp_path,
        BOOTSTRAP_TOKEN="bootstrap-secret",
        ZOTERO_SERVICE_TOKEN="library-secret",
        LLM_BACKEND="fake",
        CODEX_HOME_DIR=tmp_path / "codex-home",
        CODEX_WORKSPACE=tmp_path / "codex-workspace",
        _env_file=None,
    )
    monkeypatch.setattr("paperchat.main.load_settings", lambda: settings)
    app.dependency_overrides[load_settings] = lambda: settings

    async def metadata(self, attachment_key):
        return {
            "attachment_key": attachment_key,
            "parent_item_key": "ITEM1",
            "filename": "paper.pdf",
            "title": "Test Paper",
            "creators": [{"name": "Ada Lovelace"}],
            "year": "1843",
            "library_type": "user",
            "library_id": "123",
        }

    async def pages(self, attachment_key, start, end):
        return {
            "canonical_id": f"attachment:{attachment_key}:pages:{start}-{end}",
            "text": f"[page {start}]\nTest evidence.",
        }

    async def text_availability(self, attachment_key):
        return True

    async def papers(self, limit=500, offset=0):
        return {
            "papers": [
                {
                    "item_key": "ITEM1",
                    "attachment_key": "ATT1",
                    "title": "Test Paper",
                    "creators": [{"name": "Ada Lovelace"}],
                    "year": "1843",
                }
            ]
        }

    async def search(
        self,
        query,
        limit=20,
        offset=0,
        evidence_limit=5,
        caller="paperchat",
    ):
        papers = [
            {
                "item_key": f"ITEM{index + 1}",
                "attachment_key": f"ATT{index + 1}",
                "title": f"Test Paper {index + 1}",
                "creators": [{"name": "Ada Lovelace"}],
                "year": "1843",
                "evidence": [],
                "match_count": 1,
                "has_more_evidence": False,
            }
            for index in range(offset, offset + limit)
        ]
        return {
            "papers": papers,
            "offset": offset,
            "limit": limit,
            "has_more": offset + limit < 100,
            "next_offset": offset + len(papers),
            "total": 100,
            "paper_count": 10,
            "evidence_limit": evidence_limit,
        }

    monkeypatch.setattr("paperchat.library.ZoteroLibrary.metadata", metadata)
    monkeypatch.setattr("paperchat.library.ZoteroLibrary.pages", pages)
    monkeypatch.setattr(
        "paperchat.library.ZoteroLibrary.text_availability", text_availability
    )
    monkeypatch.setattr("paperchat.library.ZoteroLibrary.papers", papers)
    monkeypatch.setattr("paperchat.library.ZoteroLibrary.search", search)
    return TestClient(app)


def register(client: TestClient) -> dict:
    response = client.post(
        "/api/auth/register",
        json={
            "bootstrap_token": "bootstrap-secret",
            "device_id": "test-device",
            "device_name": "Test iPad",
        },
    )
    assert response.status_code == 200
    return response.json()


def test_auth_refresh_rotates_session(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        tokens = register(client)
        refreshed = client.post(
            "/api/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
        )
        reused = client.post("/api/auth/refresh", json={"refresh_token": tokens["refresh_token"]})

    assert refreshed.status_code == 200
    assert refreshed.json()["refresh_token"] != tokens["refresh_token"]
    assert reused.status_code == 401


def test_paper_thread_reading_state_and_streaming_chat(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        tokens = register(client)
        headers = {"Authorization": f"Bearer {tokens['access_token']}"}
        models = client.get("/api/models", headers=headers)
        resolved = client.post(
            "/api/papers/resolve", json={"attachment_key": "ATT1"}, headers=headers
        )
        assert resolved.status_code == 200
        paper = resolved.json()
        availability = client.get(
            f"/api/papers/{paper['id']}/text-availability", headers=headers
        )

        thread_response = client.post(
            f"/api/papers/{paper['id']}/threads", json={"title": "Main"}, headers=headers
        )
        assert thread_response.status_code == 201
        thread = thread_response.json()

        state = client.patch(
            f"/api/papers/{paper['id']}/reading-state",
            json={"page_index": 4, "active_thread_id": thread["id"]},
            headers=headers,
        )
        chat = client.post(
            f"/api/threads/{thread['id']}/messages",
            json={
                "content": "What is the result?",
                "current_page_index": 4,
                "selected_text": "Test evidence.",
                "client_request_id": "request-1",
                "model": "fake",
                "effort": "high",
            },
            headers=headers,
        )
        messages = client.get(f"/api/threads/{thread['id']}/messages", headers=headers).json()
        paper_after = client.get(f"/api/papers/{paper['id']}", headers=headers).json()

    assert state.status_code == 200
    assert models.status_code == 200
    assert models.json()["models"][0]["id"] == "fake"
    assert models.json()["models"][0]["default_reasoning_effort"] == "medium"
    assert availability.json() == {"available": True}
    assert chat.status_code == 200
    events = [
        line.removeprefix("event: ")
        for line in chat.text.splitlines()
        if line.startswith("event: ")
    ]
    assert events[0] == "message"
    assert events[-1] == "done"
    assert set(events[1:-1]) == {"delta"}
    assert [message["role"] for message in messages] == ["user", "assistant"]
    assert messages[1]["status"] == "completed"
    assert "[p. 1]" in messages[1]["content"]
    assert paper_after["reading_state"]["page_index"] == 4


def test_thread_event_broker_coalesces_invalidations():
    broker = ThreadEventBroker()
    queue = broker.subscribe("thread-1")

    broker.publish("thread-1")
    broker.publish("thread-1")
    broker.publish("another-thread")

    assert queue.qsize() == 1
    assert queue.get_nowait() == 2
    broker.unsubscribe("thread-1", queue)
    broker.publish("thread-1")
    assert queue.empty()


def test_thread_rejects_a_second_generation(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        headers = {"Authorization": f"Bearer {register(client)['access_token']}"}
        paper = client.post(
            "/api/papers/resolve", json={"attachment_key": "ATT1"}, headers=headers
        ).json()
        thread = client.post(
            f"/api/papers/{paper['id']}/threads", json={"title": "Main"}, headers=headers
        ).json()
        with connect(tmp_path / "database" / "paperchat.sqlite3") as conn:
            conn.execute(
                "UPDATE threads SET backend_status = 'streaming', updated_at = ? WHERE id = ?",
                (now(), thread["id"]),
            )

        response = client.post(
            f"/api/threads/{thread['id']}/messages",
            json={
                "content": "Can this overlap?",
                "current_page_index": 0,
                "client_request_id": "request-overlap",
            },
            headers=headers,
        )
        messages = client.get(
            f"/api/threads/{thread['id']}/messages", headers=headers
        ).json()

    assert response.status_code == 409
    assert response.json()["detail"] == "Thread is already generating a response"
    assert messages == []


def test_text_availability_is_false_without_indexed_text(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        headers = {"Authorization": f"Bearer {register(client)['access_token']}"}
        paper = client.post(
            "/api/papers/resolve", json={"attachment_key": "ATT1"}, headers=headers
        ).json()

        async def unavailable(self, attachment_key):
            return False

        monkeypatch.setattr("paperchat.library.ZoteroLibrary.text_availability", unavailable)
        response = client.get(
            f"/api/papers/{paper['id']}/text-availability", headers=headers
        )

    assert response.status_code == 200
    assert response.json() == {"available": False}


def test_library_starred_and_chat_overview(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        headers = {"Authorization": f"Bearer {register(client)['access_token']}"}
        library = client.get("/api/library/papers", headers=headers)
        paper = client.post(
            "/api/papers/resolve", json={"attachment_key": "ATT1"}, headers=headers
        ).json()
        starred = client.patch(
            f"/api/papers/{paper['id']}/star",
            json={"starred": True},
            headers=headers,
        )
        thread = client.post(
            f"/api/papers/{paper['id']}/threads",
            json={"title": "First question"},
            headers=headers,
        ).json()
        starred_papers = client.get("/api/papers/starred", headers=headers)
        chats = client.get("/api/chats", headers=headers)

    assert library.json()["papers"][0]["attachment_key"] == "ATT1"
    assert starred.json() == {"starred": True}
    assert starred_papers.json()[0]["starred"] is True
    assert chats.json()[0]["id"] == thread["id"]
    assert chats.json()[0]["paper_title"] == "Test Paper"


def test_library_search_supports_pagination(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        headers = {"Authorization": f"Bearer {register(client)['access_token']}"}
        response = client.get(
            "/api/library/search",
            params={"q": "analytical engine", "limit": 40, "offset": 40},
            headers=headers,
        )

    assert response.status_code == 200
    payload = response.json()
    assert len(payload["papers"]) == 40
    assert payload["papers"][0]["attachment_key"] == "ATT41"
    assert payload["has_more"] is True
    assert payload["next_offset"] == 80


def test_resolve_is_stable_for_same_attachment(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        headers = {"Authorization": f"Bearer {register(client)['access_token']}"}
        first = client.post(
            "/api/papers/resolve", json={"attachment_key": "ATT1"}, headers=headers
        ).json()
        second = client.post(
            "/api/papers/resolve", json={"attachment_key": "ATT1"}, headers=headers
        ).json()

    assert first["id"] == second["id"]
    assert first["identifiers"] == second["identifiers"]
