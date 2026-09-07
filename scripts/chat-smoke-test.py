#!/usr/bin/env python3
"""Send a real management-chat turn through the deployed API, without printing credentials.

Run inside the API container. Supply a prompt as an argument or a file; no skill
or repository is built into this check. Reuse --thread-id to verify later turns.
"""
from __future__ import annotations

import argparse
import json
import urllib.request
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--base-url", default="http://127.0.0.1:8000")
parser.add_argument("--thread-id")
parser.add_argument("--title", default="Management verification")
prompt_group = parser.add_mutually_exclusive_group(required=True)
prompt_group.add_argument("--prompt")
prompt_group.add_argument("--prompt-file", type=Path)
parser.add_argument("--expect", help="Text required in the completed answer")
args = parser.parse_args()


def request(method, path, payload=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.urlopen(urllib.request.Request(
        args.base_url + path, method=method, headers=headers,
        data=json.dumps(payload).encode() if payload is not None else None,
    ), timeout=3600)


with request("POST", "/api/auth/register", {
    "bootstrap_token": Path("/run/secrets/paperchat_bootstrap_token").read_text().strip(),
    "device_id": str(uuid.uuid4()), "device_name": "Management verification",
}) as response:
    tokens = json.load(response)
token = tokens["access_token"]
try:
    thread_id = args.thread_id
    if not thread_id:
        with request("POST", "/api/chats", {"title": args.title}, token) as response:
            thread_id = json.load(response)["id"]
    print(json.dumps({"thread_id": thread_id}), flush=True)
    prompt = args.prompt if args.prompt is not None else args.prompt_file.read_text()
    with request("POST", f"/api/threads/{thread_id}/messages", {
        "content": prompt, "client_request_id": str(uuid.uuid4()),
    }, token) as response:
        event = ""
        completed = False
        for raw in response:
            line = raw.decode().strip()
            if line.startswith("event: "):
                event = line[7:]
            elif line.startswith("data: "):
                payload = json.loads(line[6:])
                if event in {"progress", "error", "done"}:
                    print(json.dumps({"event": event, "data": payload}, ensure_ascii=False),
                          flush=True)
                if event == "error":
                    raise RuntimeError(payload.get("detail", "Turn failed"))
                completed |= event == "done"
        if not completed:
            raise RuntimeError("Stream ended without completion")
    with request("GET", f"/api/threads/{thread_id}/messages", token=token) as response:
        messages = json.load(response)
    answer = messages[-1]
    assert answer["status"] == "completed"
    if args.expect:
        assert args.expect in answer["content"], "Expected text missing from answer"
    print(json.dumps({"thread_id": thread_id, "answer": answer["content"],
                      "message_count": len(messages)}, ensure_ascii=False), flush=True)
finally:
    with request("DELETE", f"/api/sessions/{tokens['session_id']}", token=token):
        pass
