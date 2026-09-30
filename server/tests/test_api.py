from __future__ import annotations

from fastapi.testclient import TestClient
from paperchat.config import Settings, load_settings
from paperchat.db import connect, now
from paperchat.library import ZoteroLibraryError
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

    async def structure(self, attachment_key):
        return {
            "attachment_key": attachment_key,
            "status": "ready",
            "parser": "grobid",
            "parser_version": "0.9.1",
            "citation_consolidation": "none",
            "outline": [
                {
                    "id": "section-1",
                    "parent_id": None,
                    "title": "Introduction",
                    "level": 1,
                    "anchor": {"page_index": 0, "rects": []},
                }
            ],
            "figures": [],
            "formulas": [],
            "references": [],
            "links": [],
        }

    async def mineru(self, attachment_key, etag):
        if etag == '"mineru-test"':
            return 304, {"etag": etag}, b""
        return 200, {"etag": '"mineru-test"'}, b"PK\x03\x04test"

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
    monkeypatch.setattr("paperchat.library.ZoteroLibrary.structure", structure)
    monkeypatch.setattr("paperchat.library.ZoteroLibrary.mineru", mineru)
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


def test_zotero_library_error_is_returned_as_stable_api_error(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        headers = {"Authorization": f"Bearer {register(client)['access_token']}"}

        async def unavailable(self, attachment_key):
            raise ZoteroLibraryError("zotero_unavailable", 502)

        monkeypatch.setattr("paperchat.library.ZoteroLibrary.metadata", unavailable)
        response = client.post(
            "/api/papers/resolve", json={"attachment_key": "ATT1"}, headers=headers
        )

    assert response.status_code == 502
    assert response.json() == {"error": "zotero_unavailable"}


def test_local_zotero_open_is_adopted_after_library_sync(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        headers = {"Authorization": f"Bearer {register(client)['access_token']}"}
        local = client.post(
            "/api/papers/resolve-local",
            json={"attachment_key": "ABCDEFGH", "filename": "new-paper.pdf"},
            headers=headers,
        )
        synced = client.post(
            "/api/papers/resolve",
            json={"attachment_key": "ABCDEFGH"},
            headers=headers,
        )

    assert local.status_code == 200
    assert local.json()["title"] == "new-paper"
    assert local.json()["identifiers"] == [
        {"kind": "zotero", "library_type": "", "library_id": "", "value": "ABCDEFGH"}
    ]
    assert synced.status_code == 200
    assert synced.json()["id"] == local.json()["id"]
    assert synced.json()["title"] == "Test Paper"
    assert synced.json()["identifiers"][0] == {
        "kind": "zotero",
        "library_type": "user",
        "library_id": "123",
        "value": "ABCDEFGH",
    }


def test_local_zotero_open_rejects_invalid_attachment_key(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        headers = {"Authorization": f"Bearer {register(client)['access_token']}"}
        response = client.post(
            "/api/papers/resolve-local",
            json={"attachment_key": "../unsafe", "filename": "paper.pdf"},
            headers=headers,
        )

    assert response.status_code == 422


def test_mineru_archive_is_proxied_with_conditional_etag(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        headers = {"Authorization": f"Bearer {register(client)['access_token']}"}
        paper = client.post(
            "/api/papers/resolve", json={"attachment_key": "ATT1"}, headers=headers
        ).json()
        path = f"/api/papers/{paper['id']}/mineru"
        archive = client.get(path, headers=headers)
        cached = client.get(path, headers={**headers, "If-None-Match": '"mineru-test"'})
    assert archive.status_code == 200
    assert archive.content == b"PK\x03\x04test"
    assert archive.headers["etag"] == '"mineru-test"'
    assert cached.status_code == 304


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
        structure = client.get(f"/api/papers/{paper['id']}/structure", headers=headers)

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
    assert structure.status_code == 200
    assert structure.json()["outline"][0]["title"] == "Introduction"
    assert chat.status_code == 200
    events = [
        line.removeprefix("event: ")
        for line in chat.text.splitlines()
        if line.startswith("event: ")
    ]
    assert events[0] == "message"
    assert events[-1] == "done"
    assert set(events[1:-1]) == {"progress", "delta"}
    assert [message["role"] for message in messages] == ["user", "assistant"]
    assert messages[1]["status"] == "completed"
    assert "[p. 1]" in messages[1]["content"]
    assert "Checking the supplied pages" not in messages[1]["content"]
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


def test_bookmarks_selection_anchors_and_reading_suggestions(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        headers = {"Authorization": f"Bearer {register(client)['access_token']}"}
        paper = client.post(
            "/api/papers/resolve", json={"attachment_key": "ATT1"}, headers=headers
        ).json()
        base = f"/api/papers/{paper['id']}"

        viewed = client.post(
            f"{base}/page-views",
            json={"page_index": 2, "active_seconds": 50, "new_visit": True},
            headers=headers,
        )
        suggested = client.get(f"{base}/bookmarks", headers=headers).json()

        page_bookmark = client.post(
            f"{base}/bookmarks",
            json={"kind": "page", "page_index": 2, "page_position": 0.35},
            headers=headers,
        )
        updated_page_bookmark = client.post(
            f"{base}/bookmarks",
            json={"kind": "page", "page_index": 2, "page_position": 0.4},
            headers=headers,
        )
        selection_bookmark = client.post(
            f"{base}/bookmarks",
            json={
                "kind": "selection",
                "page_index": 3,
                "page_position": 0.77,
                "selected_text": "A selected result",
                "selection_rects": [
                    {
                        "page_index": 3,
                        "x": 0.1,
                        "y": 0.2,
                        "width": 0.5,
                        "height": 0.08,
                    }
                ],
            },
            headers=headers,
        )
        after_add = client.get(f"{base}/bookmarks", headers=headers).json()
        deleted = client.delete(
            f"/api/bookmarks/{page_bookmark.json()['id']}", headers=headers
        )
        after_delete = client.get(f"{base}/bookmarks", headers=headers).json()
        invalid_selection = client.post(
            f"{base}/bookmarks",
            json={
                "kind": "selection",
                "page_index": 1,
                "page_position": 0.2,
                "selected_text": "missing anchor",
            },
            headers=headers,
        )
        invalid_page_position = client.post(
            f"{base}/bookmarks",
            json={"kind": "page", "page_index": 2, "page_position": 1.01},
            headers=headers,
        )

    assert viewed.status_code == 200
    assert suggested["suggestions"][0]["page_index"] == 2
    assert page_bookmark.status_code == 201
    assert updated_page_bookmark.json()["id"] == page_bookmark.json()["id"]
    assert updated_page_bookmark.json()["page_position"] == 0.4
    assert selection_bookmark.status_code == 201
    assert selection_bookmark.json()["page_position"] == 0.77
    assert selection_bookmark.json()["selection_rects"][0]["page_index"] == 3
    assert len(after_add["bookmarks"]) == 2
    assert after_add["suggestions"] == []
    assert deleted.status_code == 204
    assert after_delete["suggestions"][0]["page_index"] == 2
    assert invalid_selection.status_code == 422
    assert invalid_page_position.status_code == 422


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
