"""Public entry points for portable PaperChat PDF references."""
from html import escape
from urllib.parse import urlencode

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import HTMLResponse

router = APIRouter()
LINK_BASE_URL = "https://paper-chat.fujiy.dev"


def paper_url(attachment: str, page: int | None = None) -> str:
    params = {"attachment": attachment}
    if page is not None:
        params["page"] = str(page)
    return f"{LINK_BASE_URL}/open?{urlencode(params)}"


@router.get("/.well-known/apple-app-site-association", include_in_schema=False)
def association():
    return {"applinks": {"details": [{
        "appIDs": ["4C4TXA6S8J.dev.fujiy.PaperChat"],
        "components": [{"/": "/open"}],
    }]}}


@router.get("/open", response_class=HTMLResponse, include_in_schema=False)
def open_paper(
    request: Request,
    attachment: str = Query(pattern=r"^[A-Z0-9]{8}$"),
    page: int | None = Query(default=None, ge=1, le=9223372036854775807),
):
    for name in ("attachment", "page"):
        if len(request.query_params.getlist(name)) > 1:
            raise HTTPException(422, f"Duplicate {name}")
    raw_page = request.query_params.get("page")
    if raw_page is not None and (not raw_page.isascii() or not raw_page.isdecimal()):
        raise HTTPException(422, "Invalid page")
    params = {"attachment": attachment}
    if page is not None:
        params["page"] = str(page)
    app_url = escape("paperchat://open?" + urlencode(params), quote=True)
    location = escape(attachment + (f" · PDF page {page}" if page is not None else ""))
    return HTMLResponse(f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Open in PaperChat</title><style>
body {{ font-family: system-ui, sans-serif; max-width: 32rem; margin: 15vh auto;
       padding: 1.5rem; color: #202124; background: #fafafa; }}
a {{ display: inline-block; padding: .8rem 1.2rem; border-radius: .7rem;
     background: #2457c5; color: white; text-decoration: none; }}
p {{ line-height: 1.6; }}
</style></head><body><h1>Open in PaperChat</h1><p>{location}</p>
<p><a href="{app_url}">Open in PaperChat</a></p>
<p>Install PaperChat and sign in to the server containing this Zotero PDF.
If the app does not open, check that PaperChat is installed.</p>
</body></html>""", headers={
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
        "Referrer-Policy": "no-referrer",
        "Cache-Control": "no-store",
    })
