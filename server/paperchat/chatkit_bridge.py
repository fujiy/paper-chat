"""ChatKit protocol adapter over PaperChat's existing messages and generation lifecycle.

The SDK types keep the wire format checked. PaperChat remains the only persistence
and generation owner: both UIs share IDs, locks, context assembly and Codex sessions.
"""
from __future__ import annotations

import json
import re
from contextlib import aclosing

from chatkit import types as ck
from fastapi import HTTPException
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel, Field, TypeAdapter, ValidationError

from .db import connect, new_id


class ChatContext(BaseModel):
    paper_id: str | None = Field(default=None, max_length=200)
    current_page_index: int = Field(default=0, ge=0)
    selected_text: str | None = Field(default=None, max_length=20000)
    model: str | None = Field(default=None, min_length=1, max_length=200)
    effort: str | None = Field(default=None, min_length=1, max_length=64)
    client_request_id: str = Field(default_factory=new_id, min_length=1, max_length=200)


def citation_links(text: str) -> str:
    # ChatKit accepts \(...\) inline math, while SwiftMath also accepts $...$.
    # Keep code spans/fences verbatim and leave currency-looking text alone.
    blocks = re.split(r"(```[\s\S]*?(?:```|\Z)|`[^`\n]*`)", text)
    for index in range(0, len(blocks), 2):
        block = re.sub(
            r"(?<![\\$])\$([^\s$](?:[^$\n]*?[^\s$])?)\$(?![\w$])",
            lambda match: r"\(" + match[1] + r"\)", blocks[index],
        )
        block = re.sub(r"paperchat://page/(\d+)", r"https://paperchat.invalid/page/\1", block)
        blocks[index] = re.sub(
            r"\[p\.\s*(\d+)\](?!\()",
            r"[p. \1](https://paperchat.invalid/page/\1)", block,
        )
    return "".join(blocks)


def item_from_row(row):
    common = {"id": row["id"], "thread_id": row["thread_id"], "created_at": row["created_at"]}
    if row["role"] == "user":
        pages = json.loads(row["page_refs_json"])
        quote = []
        if pages:
            quote.append("Page " + ", ".join(str(p["page_index"] + 1) for p in pages))
        if row["selected_text"]:
            quote.append(row["selected_text"])
        return ck.UserMessageItem(
            **common, content=[ck.UserMessageTextContent(text=row["content"])],
            quoted_text="\n".join(quote) or None, inference_options=ck.InferenceOptions(),
        )
    content = row["content"]
    if row["status"] == "failed":
        content += "\n\nResponse interrupted. Send a new message to continue."
    elif row["status"] == "streaming" and not content:
        content = "A response is being generated. Reload to see the result."
    return ck.AssistantMessageItem(
        **common, content=[ck.AssistantMessageContent(text=citation_links(content))],
    )


def workflow_item(row, tasks):
    terminal = row["status"] != "streaming"
    return ck.WorkflowItem(
        id="workflow_" + row["id"], thread_id=row["thread_id"], created_at=row["created_at"],
        workflow=ck.Workflow(type="custom", summary=ck.CustomSummary(title="Progress"), tasks=[
            ck.CustomTask(
                title=task.get("title") or "Working",
                content=task.get("detail") or None,
                status_indicator=("none" if task.get("status") == "failed" else
                                  "complete" if terminal or task.get("status") == "completed"
                                  else "loading"),
            ) for task in tasks.values()
        ]),
    )


def page_of(records, after=None, limit=20):
    limit = min(max(limit or 20, 1), 100)
    if after:
        index = next((i for i, r in enumerate(records) if r.id == after), None)
        if index is None:
            raise HTTPException(400, "Invalid history cursor")
        records = records[index + 1:]
    selected = records[:limit]
    more = len(records) > limit
    return ck.Page(data=selected, has_more=more, after=selected[-1].id if more else None)


def load_thread(thread_id, context, settings):
    with connect(settings.resolved_database_path) as conn:
        row = conn.execute("SELECT * FROM threads WHERE id = ?", (thread_id,)).fetchone()
    if row is None or row["paper_id"] != context.paper_id:
        raise HTTPException(404, "Thread not found in this workspace")
    status = (
        ck.LockedStatus(reason="A response is being generated. Reload when it completes.")
        if row["backend_status"] == "streaming" else ck.ActiveStatus()
    )
    return ck.Thread(
        id=row["id"], title=row["title"], created_at=row["created_at"],
        status=status, items=ck.Page(),
    )


def load_items(thread_id, settings, order="asc", after=None, limit=20):
    with connect(settings.resolved_database_path) as conn:
        rows = conn.execute(
            "SELECT * FROM messages WHERE thread_id = ? ORDER BY created_at, rowid", (thread_id,),
        ).fetchall()
        progress = {r["message_id"]: json.loads(r["items_json"]) for r in conn.execute(
            "SELECT p.* FROM message_progress p JOIN messages m ON m.id = p.message_id "
            "WHERE m.thread_id = ?", (thread_id,),
        )}
    records = []
    for row in rows:
        if progress.get(row["id"]):
            records.append(workflow_item(row, progress[row["id"]]))
        records.append(item_from_row(row))
    if order == "desc":
        records.reverse()
    return page_of(records, after, limit)


def json_response(value):
    return Response(value.model_dump_json(exclude_none=True), media_type="application/json")


def event_bytes(event):
    return "data: " + event.model_dump_json(exclude_none=True) + "\n\n"


async def handle_request(body: bytes, session, settings):
    from . import main

    try:
        request = TypeAdapter(ck.ChatKitReq).validate_json(body)
        context = ChatContext.model_validate(request.metadata.get("paperchat", {}))
    except ValidationError as error:
        raise HTTPException(422, "Invalid ChatKit request") from error

    if isinstance(request, ck.ThreadsListReq):
        with connect(settings.resolved_database_path) as conn:
            rows = conn.execute(
                "SELECT id FROM threads WHERE paper_id IS ? ORDER BY last_used_at, rowid",
                (context.paper_id,),
            ).fetchall()
        threads = [load_thread(r["id"], context, settings) for r in rows]
        if request.params.order == "desc":
            threads.reverse()
        return json_response(page_of(threads, request.params.after, request.params.limit))

    if isinstance(request, (ck.ThreadsGetByIdReq, ck.ItemsListReq)):
        thread = load_thread(request.params.thread_id, context, settings)
        if isinstance(request, ck.ItemsListReq):
            return json_response(load_items(
                thread.id, settings, request.params.order, request.params.after, request.params.limit,
            ))
        thread.items = load_items(thread.id, settings)
        return json_response(thread)

    if not isinstance(request, (ck.ThreadsCreateReq, ck.ThreadsAddUserMessageReq)):
        raise HTTPException(400, "This action is not enabled in the ChatKit prototype")
    user_input = request.params.input
    if user_input.attachments or any(p.type != "input_text" for p in user_input.content):
        raise HTTPException(400, "Only text messages are supported in this prototype")
    content = "\n".join(p.text for p in user_input.content).strip()
    model = user_input.inference_options.model or context.model
    effort = context.effort
    if model and model.startswith("paperchat:"):
        try:
            pair = json.loads(model.removeprefix("paperchat:"))
            if not isinstance(pair, list) or len(pair) != 2 or not all(
                isinstance(value, str) and 0 < len(value) <= 200 for value in pair
            ):
                raise ValueError("Invalid model selection")
            model, effort = pair
        except (ValueError, TypeError) as error:
            raise HTTPException(422, "Invalid model selection") from error
    try:
        payload = main.MessageRequest(
            content=content, current_page_index=context.current_page_index,
            selected_text=context.selected_text or user_input.quoted_text,
            client_request_id=context.client_request_id,
            model=model, effort=effort,
        )
    except ValidationError as error:
        raise HTTPException(422, "Invalid message") from error
    created = isinstance(request, ck.ThreadsCreateReq)
    if created:
        title = main.ThreadRequest(title=content[:80])
        if context.paper_id:
            row = main.create_thread(context.paper_id, title, session, settings)
        else:
            row = main.create_management_chat(title, session, settings)
        thread = load_thread(row["id"], context, settings)
    else:
        thread = load_thread(request.params.thread_id, context, settings)
    # This is the same generation path as the native UI, including its atomic lock,
    # duplicate request guard, PDF context, persistence and cancellation cleanup.
    upstream = await main.send_message(thread.id, payload, session, settings)

    async def generate():
        assistant = None
        assistant_added = False
        progress = {}
        workflow = None
        async with aclosing(upstream.body_iterator) as stream:
            first = await anext(stream)
            if created:
                yield event_bytes(ck.ThreadCreatedEvent(thread=thread))
            yield event_bytes(ck.StreamOptionsEvent(stream_options=ck.StreamOptions(allow_cancel=True)))

            async def chunks():
                yield first
                async for chunk in stream:
                    yield chunk

            async for chunk in chunks():
                text = chunk.decode() if isinstance(chunk, bytes) else chunk
                lines = text.splitlines()
                name = next((line[7:] for line in lines if line.startswith("event: ")), "")
                data = json.loads(next(line[6:] for line in lines if line.startswith("data: ")))
                if name == "message":
                    with connect(settings.resolved_database_path) as conn:
                        user = conn.execute(
                            "SELECT * FROM messages WHERE id = ?", (data["user_message_id"],),
                        ).fetchone()
                        row = conn.execute(
                            "SELECT * FROM messages WHERE id = ?", (data["message_id"],),
                        ).fetchone()
                    yield event_bytes(ck.ThreadItemDoneEvent(item=item_from_row(user)))
                    assistant = ck.AssistantMessageItem(
                        id=row["id"], thread_id=thread.id, created_at=row["created_at"],
                        content=[ck.AssistantMessageContent(text="")],
                    )
                elif name == "delta" and assistant:
                    if not assistant_added:
                        yield event_bytes(ck.ThreadItemAddedEvent(item=assistant))
                        assistant_added = True
                    assistant.content[0].text += data["delta"]
                    yield event_bytes(ck.ThreadItemUpdatedEvent(
                        item_id=assistant.id,
                        update=ck.AssistantMessageContentPartTextDelta(
                            content_index=0, delta=data["delta"],
                        ),
                    ))
                elif name == "answer" and assistant:
                    if not assistant_added:
                        yield event_bytes(ck.ThreadItemAddedEvent(item=assistant))
                        assistant_added = True
                    assistant.content[0].text = data["content"]
                    yield event_bytes(ck.ThreadItemReplacedEvent(item=assistant))
                elif name == "progress" and assistant:
                    key = data.get("id") or data.get("title") or "progress"
                    previous = progress.get(key, {})
                    detail = data.get("detail") or ""
                    if data.get("operation") == "append":
                        detail = previous.get("detail", "") + detail
                    progress[key] = {**data, "detail": detail}
                    with connect(settings.resolved_database_path) as conn:
                        conn.execute(
                            "INSERT OR REPLACE INTO message_progress VALUES (?, ?)",
                            (assistant.id, json.dumps(progress)),
                        )
                    updated = workflow_item(row, progress)
                    yield event_bytes(ck.ThreadItemReplacedEvent(item=updated) if workflow else
                                      ck.ThreadItemAddedEvent(item=updated))
                    workflow = updated
                elif name == "done" and assistant:
                    if workflow:
                        workflow = workflow_item(dict(row) | {"status": "completed"}, progress)
                        yield event_bytes(ck.ThreadItemDoneEvent(item=workflow))
                    assistant.content[0].text = citation_links(assistant.content[0].text)
                    yield event_bytes(ck.ThreadItemDoneEvent(item=assistant))
                elif name == "error":
                    if workflow:
                        workflow = workflow_item(dict(row) | {"status": "failed"}, progress)
                        yield event_bytes(ck.ThreadItemDoneEvent(item=workflow))
                    yield event_bytes(ck.ErrorEvent(
                        message="Response failed. Reload the conversation and try again.",
                        allow_retry=False,
                    ))
        yield event_bytes(ck.ThreadUpdatedEvent(thread=load_thread(thread.id, context, settings)))

    return StreamingResponse(generate(), media_type="text/event-stream", headers={
        "Cache-Control": "no-store", "X-Accel-Buffering": "no",
    })
