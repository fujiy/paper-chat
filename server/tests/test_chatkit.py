from __future__ import annotations

from chatkit import types as ck
from paperchat.config import load_settings
from paperchat.db import connect
from paperchat.llm import FakeBackend, LLMEvent
from paperchat.main import app
from pydantic import TypeAdapter
from test_api import client_for, register


def operation(client, headers, kind, params, **context):
    return client.post('/api/chatkit', headers=headers, json={
        'type': kind, 'params': params, 'metadata': {'paperchat': context},
    })


def user_input(text='Explain this equation'):
    return {'content': [{'type': 'input_text', 'text': text}],
            'attachments': [], 'inference_options': {}}


def events(response):
    assert response.status_code == 200, response.text
    return [TypeAdapter(ck.ThreadStreamEvent).validate_json(line[6:])
            for line in response.text.splitlines() if line.startswith('data: ')]


def test_chatkit_shares_native_history_context_and_resume(tmp_path, monkeypatch):
    calls = []

    async def stream(self, prompt, backend_thread_id=None, model=None, effort=None, mode='paper'):
        calls.append((prompt, backend_thread_id, model, effort, mode))
        yield LLMEvent('thread', backend_thread_id='codex-existing-thread')
        yield LLMEvent('delta', text='Interim')
        yield LLMEvent('answer', text='Final $x^2$ [p. 3]')
        yield LLMEvent('done', backend_turn_id='turn-1')

    monkeypatch.setattr(FakeBackend, 'stream', stream)
    with client_for(tmp_path, monkeypatch) as client:
        headers = {'Authorization': f"Bearer {register(client)['access_token']}"}
        paper = client.post('/api/papers/resolve', headers=headers,
                            json={'attachment_key': 'ATT1'}).json()
        context = {'paper_id': paper['id'], 'current_page_index': 2,
                   'selected_text': 'Selected equation', 'model': 'fake', 'effort': 'high'}
        result = events(operation(client, headers, 'threads.create',
                                  {'input': user_input()}, **context))
        thread_id = result[0].thread.id
        final = [e.item for e in result if isinstance(e, ck.ThreadItemDoneEvent)][-1]
        assert 'https://paperchat.invalid/page/3' in final.content[0].text
        assert 'Interim' not in final.content[0].text
        native = client.get(f'/api/threads/{thread_id}/messages', headers=headers).json()
        assert len(native) == 2
        assert native[0]['selected_text'] == 'Selected equation'
        assert native[0]['page_refs'] == [{'page_index': 2}]
        assert native[1]['content'] == 'Final $x^2$ [p. 3]'
        assert native[1]['status'] == 'completed'
        assert 'Current PDF page: 3' in calls[0][0]
        assert calls[0][2:] == ('fake', 'high', 'paper')
        assert 'Selected equation' in calls[0][0]
        # A second authenticated device gets the same history on opening.
        second = {'Authorization': f"Bearer {register(client)['access_token']}"}
        reopened = operation(client, second, 'threads.get_by_id',
                             {'thread_id': thread_id}, **context)
        parsed = ck.Thread.model_validate(reopened.json())
        assert [i.id for i in parsed.items.data] == [i['id'] for i in native]
        assert 'Page 3' in parsed.items.data[0].quoted_text
        events(operation(client, second, 'threads.add_user_message',
                         {'thread_id': thread_id, 'input': user_input('Continue')}, **context))
        assert calls[-1][1] == 'codex-existing-thread'
        assert len(client.get(f'/api/threads/{thread_id}/messages', headers=headers).json()) == 4
        # Cursor pagination is stable and does not repeat items.
        first = operation(client, headers, 'items.list',
                          {'thread_id': thread_id, 'limit': 2, 'order': 'asc'}, **context).json()
        last = operation(client, headers, 'items.list',
                         {'thread_id': thread_id, 'limit': 2, 'order': 'asc',
                          'after': first['after']}, **context).json()
        assert first['has_more'] and not last['has_more']
        assert len({i['id'] for i in first['data'] + last['data']}) == 4


def test_chatkit_auth_scope_duplicates_and_unsupported_actions(tmp_path, monkeypatch):
    with client_for(tmp_path, monkeypatch) as client:
        assert operation(client, {}, 'threads.list', {}).status_code == 401
        headers = {'Authorization': f"Bearer {register(client)['access_token']}"}
        result = events(operation(client, headers, 'threads.create', {'input': user_input()},
                                  client_request_id='unique'))
        thread_id = result[0].thread.id
        assert operation(client, headers, 'threads.get_by_id', {'thread_id': thread_id},
                         paper_id='another-paper').status_code == 404
        params = {'thread_id': thread_id, 'input': user_input()}
        assert operation(client, headers, 'threads.add_user_message', params,
                         client_request_id='unique').status_code == 409
        assert operation(client, headers, 'threads.delete',
                         {'thread_id': thread_id}).status_code == 400
        assert operation(client, headers, 'threads.create',
                         {'input': user_input(' ')}).status_code == 422
        settings = app.dependency_overrides[load_settings]()
        with connect(settings.resolved_database_path) as conn:
            conn.execute("UPDATE threads SET backend_status = 'streaming' WHERE id = ?", (thread_id,))
        assert operation(client, headers, 'threads.add_user_message', params).status_code == 409
        assert operation(client, headers, 'threads.get_by_id',
                         {'thread_id': thread_id}).json()['status']['type'] == 'locked'


def test_chatkit_failure_unlocks_shared_thread(tmp_path, monkeypatch):
    async def broken(self, *args, **kwargs):
        yield LLMEvent('delta', text='partial')
        raise RuntimeError('private upstream detail')

    monkeypatch.setattr(FakeBackend, 'stream', broken)
    with client_for(tmp_path, monkeypatch) as client:
        headers = {'Authorization': f"Bearer {register(client)['access_token']}"}
        response = operation(client, headers, 'threads.create', {'input': user_input()})
        result = events(response)
        thread_id = result[0].thread.id
        assert any(isinstance(e, ck.ErrorEvent) for e in result)
        assert 'private upstream detail' not in response.text
        history = operation(client, headers, 'threads.get_by_id', {'thread_id': thread_id}).json()
        assert history['status']['type'] == 'active'
        assert 'interrupted' in history['items']['data'][-1]['content'][0]['text']
        assert client.get(f'/api/threads/{thread_id}/messages', headers=headers).json()[-1]['status'] == 'failed'


def test_math_compatibility_preserves_code_and_currency():
    from paperchat.chatkit_bridge import citation_links

    assert citation_links('$x$ and $E=mc^2$') == r'\(x\) and \(E=mc^2\)'
    assert citation_links('$$x^2$$') == '$$x^2$$'
    assert citation_links('Price $5 and $10') == 'Price $5 and $10'
    assert citation_links('`$x$`\n```tex\n$x$\n```') == '`$x$`\n```tex\n$x$\n```'
    assert citation_links(r'\(x\)') == r'\(x\)'


def test_cancel_before_first_message_unlocks_thread(tmp_path, monkeypatch):
    import asyncio

    from paperchat.chatkit_bridge import handle_request

    with client_for(tmp_path, monkeypatch):
        settings = app.dependency_overrides[load_settings]()

        async def cancel():
            import json
            response = await handle_request(json.dumps({
                'type': 'threads.create', 'params': {'input': user_input()},
            }).encode(), {}, settings)
            stream = response.body_iterator
            await anext(stream)  # thread.created; UI navigates away immediately
            await stream.aclose()

        asyncio.run(cancel())
        with connect(settings.resolved_database_path) as conn:
            assert conn.execute('SELECT backend_status FROM threads').fetchone()[0] == 'ready'
            assert conn.execute("SELECT status FROM messages WHERE role = 'assistant'").fetchone()[0] == 'failed'


def test_standard_model_picker_and_persisted_workflow(tmp_path, monkeypatch):
    calls = []

    async def stream(self, prompt, backend_thread_id=None, model=None, effort=None, mode='paper'):
        calls.append((model, effort))
        for detail, status in [('First ', 'running'), ('second', 'completed')]:
            yield LLMEvent('progress', text=detail, progress_id='tool-1',
                           progress_title='Search', progress_status=status,
                           progress_operation='append')
        yield LLMEvent('answer', text='Final answer')
        yield LLMEvent('done')

    monkeypatch.setattr(FakeBackend, 'stream', stream)
    with client_for(tmp_path, monkeypatch) as client:
        headers = {'Authorization': f"Bearer {register(client)['access_token']}"}
        value = user_input()
        value['inference_options']['model'] = 'paperchat:["chosen-model","high"]'
        result = events(operation(client, headers, 'threads.create', {'input': value},
                                  model='old-model', effort='low'))
        thread_id = result[0].thread.id
        assert calls == [('chosen-model', 'high')]
        workflows = [e.item for e in result if isinstance(e, ck.ThreadItemDoneEvent)
                     and isinstance(e.item, ck.WorkflowItem)]
        assert len(workflows) == 1
        assert workflows[0].workflow.tasks[0].content == 'First second'
        assert workflows[0].workflow.tasks[0].status_indicator == 'complete'
        history = ck.Thread.model_validate(operation(client, headers, 'threads.get_by_id',
                                                    {'thread_id': thread_id}).json())
        assert [item.type for item in history.items.data] == [
            'user_message', 'workflow', 'assistant_message',
        ]
        assert history.items.data[1] == workflows[0]
        assert history.items.data[2].content[0].text == 'Final answer'
        listing = operation(client, headers, 'threads.list', {}).json()
        assert listing['data'][0]['id'] == thread_id
        assert operation(client, headers, 'threads.list', {}, paper_id='other').json()['data'] == []
        value['inference_options']['model'] = 'paperchat:bad'
        assert operation(client, headers, 'threads.create', {'input': value}).status_code == 422
