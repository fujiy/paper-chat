from __future__ import annotations

from fastapi.testclient import TestClient
from paperchat.config import Settings, load_settings
from paperchat.main import app


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

    monkeypatch.setattr("paperchat.library.ZoteroLibrary.metadata", metadata)
    monkeypatch.setattr("paperchat.library.ZoteroLibrary.pages", pages)
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
            },
            headers=headers,
        )
        messages = client.get(f"/api/threads/{thread['id']}/messages", headers=headers).json()
        paper_after = client.get(f"/api/papers/{paper['id']}", headers=headers).json()

    assert state.status_code == 200
    assert models.status_code == 200
    assert models.json()["models"][0]["id"] == "fake"
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
