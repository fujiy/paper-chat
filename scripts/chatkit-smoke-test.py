#!/usr/bin/env python3
"""Run in the deployed API container: real Codex, synthetic paper, temporary SQLite.

No real paper text or existing conversation is read or modified. The runner retains
only the synthetic Codex conversation created by this check.
"""
from __future__ import annotations

import json
import tempfile
from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient
from paperchat import main
from paperchat.config import load_settings
from paperchat.db import connect, now

production = load_settings()
with tempfile.TemporaryDirectory(prefix="paperchat-chatkit-smoke-") as directory:
    settings = production.model_copy(update={
        "data_dir": Path(directory), "database_path": Path(directory) / "smoke.sqlite3",
    })
    # cached_property values from production must not point this test at the live database.
    settings.__dict__.pop("resolved_database_path", None)
    original = main.load_settings
    main.load_settings = lambda: settings
    main.app.dependency_overrides[load_settings] = lambda: settings
    try:
        with TestClient(main.app) as client:
            assert client.get('/health').json() == {'status': 'ok'}
            assert client.post('/api/chatkit', json={'type': 'threads.list', 'params': {}}).status_code == 401
            tokens = client.post('/api/auth/register', json={
                'bootstrap_token': production.resolved_bootstrap_token,
                'device_id': str(uuid4()), 'device_name': 'ChatKit synthetic check',
            }).json()
            headers = {'Authorization': 'Bearer ' + tokens['access_token']}
            paper_id = str(uuid4())
            with connect(settings.resolved_database_path) as conn:
                conn.execute(
                    'INSERT INTO papers (id,title,created_at,updated_at) VALUES (?,?,?,?)',
                    (paper_id, 'Synthetic ChatKit verification', now(), now()),
                )
            context = {'paper_id': paper_id, 'current_page_index': 2,
                       'selected_text': 'Synthetic equation: E = mc^2'}

            def operation(kind, params, request_headers=headers):
                response = client.post('/api/chatkit', headers=request_headers, json={
                    'type': kind, 'params': params, 'metadata': {'paperchat': context},
                })
                response.raise_for_status()
                return response

            def turn(kind, text, thread_id=None):
                params = {'input': {'content': [{'type': 'input_text', 'text': text}],
                                    'attachments': [], 'inference_options': {}}}
                if thread_id:
                    params['thread_id'] = thread_id
                response = operation(kind, params)
                values = [json.loads(line[6:]) for line in response.text.splitlines()
                          if line.startswith('data: ')]
                errors = [e for e in values if e['type'] == 'error']
                assert not errors, errors
                answers = [e['item'] for e in values if e['type'] == 'thread.item.done'
                           and e['item']['type'] == 'assistant_message']
                assert answers, 'No completed assistant response'
                return values, answers[-1]

            values, answer = turn('threads.create',
                'This is a synthetic UI test. Do not use tools or read any files. '
                'Reply with CHATKIT_OK, the equation E=mc^2 in inline LaTeX, and [p. 3].')
            thread_id = next(e['thread']['id'] for e in values if e['type'] == 'thread.created')
            assert 'CHATKIT_OK' in answer['content'][0]['text']
            with connect(settings.resolved_database_path) as conn:
                backend_id = conn.execute('SELECT backend_thread_id FROM threads WHERE id=?',
                                          (thread_id,)).fetchone()[0]
            assert backend_id
            refreshed = client.post('/api/auth/refresh', json={'refresh_token': tokens['refresh_token']})
            refreshed.raise_for_status()
            refreshed_headers = {'Authorization': 'Bearer ' + refreshed.json()['access_token']}
            history = operation('threads.get_by_id', {'thread_id': thread_id}, refreshed_headers).json()
            assert len([item for item in history['items']['data']
                        if item['type'] in {'user_message', 'assistant_message'}]) == 2
            assert 'Page 3' in history['items']['data'][0]['quoted_text']
            headers.update(refreshed_headers)
            _, answer2 = turn('threads.add_user_message',
                             'Do not use tools. Reply only CHATKIT_RESUMED.', thread_id)
            assert 'CHATKIT_RESUMED' in answer2['content'][0]['text']
            native = client.get(f'/api/threads/{thread_id}/messages', headers=headers).json()
            assert len(native) == 4 and all(m['status'] == 'completed' for m in native)
            with connect(settings.resolved_database_path) as conn:
                assert conn.execute('SELECT backend_thread_id FROM threads WHERE id=?',
                                    (thread_id,)).fetchone()[0] == backend_id
            print(json.dumps({'result': 'passed', 'turns': 2, 'shared_messages': len(native),
                              'auth_refresh': True, 'codex_resume': True,
                              'real_paper_data_sent': False}))
    finally:
        main.load_settings = original
        main.app.dependency_overrides.pop(load_settings, None)
