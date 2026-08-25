from __future__ import annotations

import httpx

from .config import Settings


class ZoteroLibraryError(Exception):
    def __init__(self, code: str, status_code: int):
        super().__init__(code)
        self.code = code
        self.status_code = status_code

    @classmethod
    def from_response(cls, response: httpx.Response) -> ZoteroLibraryError:
        try:
            error = str(response.json().get("error") or "")
        except (TypeError, ValueError):
            error = ""

        if response.status_code == 404:
            return cls("zotero_attachment_not_found", 404)
        if response.status_code == 409 and error == "pdf_not_cached":
            return cls("zotero_pdf_processing", 409)
        if response.status_code in {401, 403}:
            return cls("zotero_auth_failed", 502)
        if error == "invalid_cache_path":
            return cls("zotero_pdf_cache_error", 502)
        if response.status_code >= 500:
            return cls("zotero_unavailable", 502)
        return cls("zotero_request_failed", 502)


class ZoteroLibrary:
    def __init__(self, settings: Settings):
        self.settings = settings

    @property
    def headers(self) -> dict[str, str]:
        token = self.settings.resolved_zotero_service_token
        return {"Authorization": f"Bearer {token}"} if token else {}

    async def _get(self, path: str, **kwargs) -> httpx.Response:
        try:
            async with httpx.AsyncClient(base_url=self.settings.zotero_library_url) as client:
                response = await client.get(path, **kwargs)
        except httpx.TimeoutException as error:
            raise ZoteroLibraryError("zotero_timeout", 504) from error
        except httpx.RequestError as error:
            raise ZoteroLibraryError("zotero_unavailable", 502) from error
        try:
            response.raise_for_status()
        except httpx.HTTPStatusError as error:
            raise ZoteroLibraryError.from_response(response) from error
        return response

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
        response = await self._get(
            "/internal/search",
            params={
                "q": query,
                "limit": 100,
                "evidence_limit": evidence_limit,
                "caller": caller,
            },
            headers=self.headers,
        )
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
        response = await self._get(
            "/internal/papers",
            params={"limit": limit, "offset": offset},
            headers=self.headers,
        )
        return response.json()

    async def metadata(self, attachment_key: str) -> dict:
        response = await self._get(
            f"/internal/attachments/{attachment_key}", headers=self.headers
        )
        return response.json()

    async def pages(self, attachment_key: str, start: int, end: int) -> dict:
        response = await self._get(
            f"/internal/attachments/{attachment_key}/pages",
            params={"start": start, "end": end},
            headers=self.headers,
        )
        return response.json()

    async def text_availability(self, attachment_key: str) -> bool:
        response = await self._get(
            f"/internal/attachments/{attachment_key}/text-availability",
            headers=self.headers,
        )
        return bool(response.json().get("available"))

    async def structure(self, attachment_key: str) -> dict:
        response = await self._get(
            f"/internal/attachments/{attachment_key}/structure",
            headers=self.headers,
        )
        return response.json()

    async def pdf(self, attachment_key: str, range_header: str | None) -> tuple[int, dict, bytes]:
        headers = self.headers
        if range_header:
            headers["Range"] = range_header
        response = await self._get(
            f"/internal/attachments/{attachment_key}/pdf", headers=headers
        )
        return response.status_code, dict(response.headers), response.content
