"""Internal authenticated transport for the dedicated Codex container.

It has its own persistent volume and never mounts the API database or API secrets.
"""

from __future__ import annotations

import asyncio
import json
import secrets
from contextlib import asynccontextmanager
from dataclasses import asdict
from typing import Annotated, Literal

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .config import load_settings
from .llm import CodexBackend


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = load_settings()
    if not settings.resolved_runner_token:
        raise RuntimeError("Codex runner token is required")
    settings.codex_home.mkdir(parents=True, exist_ok=True)
    settings.codex_workspace.mkdir(parents=True, exist_ok=True)
    yield


app = FastAPI(title="PaperChat Codex runner", lifespan=lifespan)


def authenticate(authorization: str = Header(default="")) -> None:
    token = load_settings().resolved_runner_token
    if not token or not secrets.compare_digest(authorization, f"Bearer {token}"):
        raise HTTPException(401, "Invalid runner credentials")


Authorized = Annotated[None, Depends(authenticate)]


class TurnRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=2_000_000)
    backend_thread_id: str | None = None
    model: str | None = None
    effort: str | None = None
    mode: Literal["paper", "management"] = "paper"


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/models")
async def models(_: Authorized):
    return await CodexBackend(load_settings()).list_models()


@app.post("/turns")
async def turn(payload: TurnRequest, _: Authorized):
    async def generate():
        try:
            async for event in CodexBackend(load_settings()).stream(**payload.model_dump()):
                yield json.dumps(asdict(event), ensure_ascii=False) + "\n"
        except asyncio.CancelledError:
            raise
        except Exception as error:
            yield json.dumps({"error": str(error)}) + "\n"

    return StreamingResponse(generate(), media_type="application/x-ndjson")
