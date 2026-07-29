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
            return {"results": [{"rank": index} for index in range(81)]}

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

    result = await ZoteroLibrary(settings).search("engine", limit=40, offset=40)

    assert requested["params"] == {"q": "engine", "limit": 81}
    assert [item["rank"] for item in result["results"]] == list(range(40, 80))
    assert result["has_more"] is True
    assert result["next_offset"] == 80
