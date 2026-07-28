#!/usr/bin/env python3
"""Verify the deployed Codex adapter with synthetic, non-sensitive prompts."""

from __future__ import annotations

import asyncio
import json

from paperchat.config import Settings
from paperchat.llm import CodexBackend


async def run_turn(
    backend: CodexBackend, prompt: str, thread_id: str | None = None
) -> tuple[str, str, int]:
    resumed_thread_id = ""
    answer = ""
    delta_count = 0
    completed = False
    async for event in backend.stream(prompt, thread_id):
        if event.kind == "thread":
            resumed_thread_id = event.backend_thread_id or ""
        elif event.kind == "delta":
            answer += event.text
            delta_count += 1
        elif event.kind == "done":
            completed = True
    if not resumed_thread_id or not answer.strip() or not completed:
        raise RuntimeError("Codex stream did not produce a complete response")
    return resumed_thread_id, answer, delta_count


async def main() -> None:
    backend = CodexBackend(Settings(LLM_BACKEND="codex"))
    thread_id, first_answer, first_deltas = await run_turn(
        backend,
        "This is a synthetic PaperChat deployment test. Reply with PAPERCHAT_CODEX_OK.",
    )
    resumed_id, second_answer, second_deltas = await run_turn(
        backend,
        "This is still synthetic test data. Reply with PAPERCHAT_RESUME_OK.",
        thread_id,
    )
    if resumed_id != thread_id:
        raise RuntimeError("Codex thread ID changed instead of resuming")
    print(
        json.dumps(
            {
                "status": "ok",
                "first_nonempty": bool(first_answer.strip()),
                "second_nonempty": bool(second_answer.strip()),
                "first_delta_count": first_deltas,
                "second_delta_count": second_deltas,
                "thread_resumed": True,
            }
        )
    )


asyncio.run(main())
