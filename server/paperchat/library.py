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

    async def search(
        self,
        query: str,
        limit: int = 20,
        offset: int = 0,
        evidence_limit: int = 5,
        caller: str | None = "paperchat",
    ) -> dict:
        # Fetch a ranked paper window from the library service, then expose stable
        # offset-based paper pagination to clients.
        async with httpx.AsyncClient(base_url=self.settings.zotero_library_url) as client:
            response = await client.get(
                "/internal/search",
                params={
                    "q": query,
                    "limit": 100,
                    "evidence_limit": evidence_limit,
                    "caller": caller,
                },
                headers=self.headers,
            )
            response.raise_for_status()
            payload = response.json()
        ranked_papers = list(payload.get("papers") or [])
        page = ranked_papers[offset : offset + limit]
        return {
            **payload,
            "papers": page,
            "offset": offset,
            "limit": limit,
            "has_more": len(ranked_papers) > offset + limit,
            "next_offset": offset + len(page),
            "total": sum(int(paper.get("match_count") or 0) for paper in ranked_papers),
            "paper_count": len(ranked_papers),
            "evidence_limit": evidence_limit,
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
