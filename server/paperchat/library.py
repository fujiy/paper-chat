from __future__ import annotations

import httpx

from .config import Settings


class ZoteroLibrary:
    def __init__(self, settings: Settings):
        self.settings = settings

    @property
    def headers(self) -> dict[str, str]:
        token = self.settings.resolved_zotero_service_token
        return {"Authorization": f"Bearer {token}"} if token else {}

    async def search(self, query: str, limit: int = 20, offset: int = 0) -> dict:
        # The library service currently exposes a ranked top-N search rather than
        # offset pagination. Fetch one item beyond the requested window so this
        # API can present stable offset-based pagination to clients.
        fetch_limit = min(offset + limit + 1, 100)
        async with httpx.AsyncClient(base_url=self.settings.zotero_library_url) as client:
            response = await client.get(
                "/internal/search",
                params={"q": query, "limit": fetch_limit},
                headers=self.headers,
            )
            response.raise_for_status()
            payload = response.json()
        ranked_results = list(payload.get("results") or [])
        page = ranked_results[offset : offset + limit]
        return {
            **payload,
            "results": page,
            "offset": offset,
            "limit": limit,
            "has_more": len(ranked_results) > offset + limit,
            "next_offset": offset + len(page),
        }

    async def papers(self, limit: int = 500, offset: int = 0) -> dict:
        async with httpx.AsyncClient(base_url=self.settings.zotero_library_url) as client:
            response = await client.get(
                "/internal/papers",
                params={"limit": limit, "offset": offset},
                headers=self.headers,
            )
            response.raise_for_status()
            return response.json()

    async def metadata(self, attachment_key: str) -> dict:
        async with httpx.AsyncClient(base_url=self.settings.zotero_library_url) as client:
            response = await client.get(
                f"/internal/attachments/{attachment_key}", headers=self.headers
            )
            response.raise_for_status()
            return response.json()

    async def pages(self, attachment_key: str, start: int, end: int) -> dict:
        async with httpx.AsyncClient(base_url=self.settings.zotero_library_url) as client:
            response = await client.get(
                f"/internal/attachments/{attachment_key}/pages",
                params={"start": start, "end": end},
                headers=self.headers,
            )
            response.raise_for_status()
            return response.json()

    async def pdf(self, attachment_key: str, range_header: str | None) -> tuple[int, dict, bytes]:
        headers = self.headers
        if range_header:
            headers["Range"] = range_header
        async with httpx.AsyncClient(base_url=self.settings.zotero_library_url) as client:
            response = await client.get(
                f"/internal/attachments/{attachment_key}/pdf", headers=headers
            )
            return response.status_code, dict(response.headers), response.content
