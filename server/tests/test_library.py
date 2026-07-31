from __future__ import annotations

import pytest
from paperchat.config import Settings
from paperchat.library import ZoteroLibrary


@pytest.mark.asyncio
async def test_search_adapts_ranked_top_n_to_offset_pagination(tmp_path, monkeypatch):
    requested: dict[str, object] = {}

    class Response:
        def raise_for_status(self):
            return None

        def json(self):
            return {
                "papers": [
                    {
                        "rank": index,
                        "item_key": f"item-{index}",
                        "attachment_key": f"paper-{index}",
                        "match_count": index + 1,
                        "evidence": [],
                    }
                    for index in range(100)
                ]
            }

    class Client:
        def __init__(self, *, base_url):
            requested["base_url"] = base_url

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_):
            return None

        async def get(self, path, *, params, headers):
            requested.update(path=path, params=params, headers=headers)
            return Response()

    monkeypatch.setattr("paperchat.library.httpx.AsyncClient", Client)
    settings = Settings(
        DATA_DIR=tmp_path,
        ZOTERO_SERVICE_TOKEN="library-secret",
        _env_file=None,
    )

    result = await ZoteroLibrary(settings).search(
        "engine",
        limit=15,
        offset=20,
        evidence_limit=3,
        caller="paperchat-test",
    )

    assert requested["params"] == {
        "q": "engine",
        "limit": 100,
        "evidence_limit": 3,
        "caller": "paperchat-test",
    }
    assert [item["rank"] for item in result["papers"]] == list(range(20, 35))
    assert result["has_more"] is True
    assert result["next_offset"] == 35
    assert result["total"] == sum(range(1, 101))
    assert result["paper_count"] == 100
