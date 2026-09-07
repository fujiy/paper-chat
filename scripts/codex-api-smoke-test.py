#!/usr/bin/env python3
"""Exercise PaperChat's HTTP/SSE/DB path with Codex and synthetic data only."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from uuid import uuid4

import paperchat.main as main_module
from fastapi.testclient import TestClient
from paperchat.config import Settings, load_settings
from paperchat.db import connect, now

app = main_module.app

with tempfile.TemporaryDirectory(prefix="paperchat-codex-api-") as data_dir:
    settings = Settings(
        DATA_DIR=Path(data_dir),
        BOOTSTRAP_TOKEN="synthetic-bootstrap-token",
        LLM_BACKEND="codex",
        CODEX_HOME_DIR=Path(os.environ.get("CODEX_HOME", str(Path(data_dir) / "home"))),
        CODEX_WORKSPACE=Path(data_dir) / "workspace",
        _env_file=None,
    )
    original_load_settings = main_module.load_settings
    main_module.load_settings = lambda: settings
    app.dependency_overrides[load_settings] = lambda: settings
    try:
        with TestClient(app) as client:
            registration = client.post(
                "/api/auth/register",
                json={
                    "bootstrap_token": "synthetic-bootstrap-token",
                    "device_id": "synthetic-smoke-device",
                    "device_name": "Synthetic smoke test",
                },
            )
            registration.raise_for_status()
            token = registration.json()["access_token"]
            headers = {"Authorization": f"Bearer {token}"}

            paper_id = str(uuid4())
            timestamp = now()
            with connect(settings.resolved_database_path) as connection:
                connection.execute(
                    """
                    INSERT INTO papers
                      (id, title, authors_json, year, created_at, updated_at, last_opened_at)
                    VALUES (?, ?, '[]', ?, ?, ?, ?)
                    """,
                    (
                        paper_id,
                        "Synthetic PaperChat Deployment Test",
                        "2026",
                        timestamp,
                        timestamp,
                        timestamp,
                    ),
                )

            thread_response = client.post(
                f"/api/papers/{paper_id}/threads",
                json={"title": "Synthetic Codex test"},
                headers=headers,
            )
            thread_response.raise_for_status()
            thread_id = thread_response.json()["id"]

            chat = client.post(
                f"/api/threads/{thread_id}/messages",
                json={
                    "content": "This is synthetic data. Reply with PAPERCHAT_API_CODEX_OK.",
                    "current_page_index": 0,
                    "selected_text": None,
                    "client_request_id": str(uuid4()),
                },
                headers=headers,
            )
            chat.raise_for_status()
            events = [
                line.removeprefix("event: ")
                for line in chat.text.splitlines()
                if line.startswith("event: ")
            ]
            if not events or events[0] != "message" or events[-1] != "done":
                raise RuntimeError(f"unexpected SSE events: {events}")

            messages_response = client.get(
                f"/api/threads/{thread_id}/messages", headers=headers
            )
            messages_response.raise_for_status()
            messages = messages_response.json()
            with connect(settings.resolved_database_path) as connection:
                backend_thread_id = connection.execute(
                    "SELECT backend_thread_id FROM threads WHERE id = ?", (thread_id,)
                ).fetchone()["backend_thread_id"]
            if (
                len(messages) != 2
                or messages[-1]["status"] != "completed"
                or not messages[-1]["content"].strip()
                or not backend_thread_id
            ):
                raise RuntimeError("Codex response or persisted state was incomplete")

            print(
                json.dumps(
                    {
                        "status": "ok",
                        "sse_event_count": len(events),
                        "messages_persisted": len(messages),
                        "assistant_completed": True,
                        "backend_thread_persisted": True,
                    }
                )
            )
    finally:
        app.dependency_overrides.clear()
        main_module.load_settings = original_load_settings
