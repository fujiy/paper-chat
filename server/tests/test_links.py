from fastapi.testclient import TestClient
from paperchat.chatkit_bridge import citation_links
from paperchat.main import app


def test_public_link_routes_need_no_authentication():
    client = TestClient(app)
    response = client.get('/.well-known/apple-app-site-association', follow_redirects=False)
    assert response.status_code == 200
    assert response.headers['content-type'] == 'application/json'
    assert response.json() == {'applinks': {'details': [{
        'appIDs': ['4C4TXA6S8J.dev.fujiy.PaperChat'],
        'components': [{'/': '/open'}],
    }]}}
    response = client.get('/open?attachment=ABCD1234&page=12', follow_redirects=False)
    assert response.status_code == 200
    assert 'paperchat://open?attachment=ABCD1234&amp;page=12' in response.text
    assert 'PDF page 12' in response.text
    assert 'frame-ancestors' in response.headers['content-security-policy']
    response = client.get('/open?attachment=ABCD1234')
    assert 'paperchat://open?attachment=ABCD1234"' in response.text


def test_invalid_links_do_not_produce_launch_buttons():
    client = TestClient(app)
    for query in (
        '', 'attachment=bad', 'attachment=%22%3E%3Cscript%3E',
        'attachment=ABCD1234&page=0', 'attachment=ABCD1234&page=-1',
        'attachment=ABCD1234&page=no', 'attachment=ABCD1234&page=1.0',
        'attachment=ABCD1234&page=9223372036854775808',
        'attachment=ABCD1234&attachment=EFGH5678',
        'attachment=ABCD1234&page=1&page=2',
    ):
        response = client.get('/open?' + query)
        assert response.status_code == 422, query
        assert 'paperchat://open' not in response.text


def test_chatkit_keeps_portable_links_and_legacy_pages():
    source = '[Other](paperchat://open?attachment=ABCD1234&page=12) [p. 2](paperchat://page/2)'
    rendered = citation_links(source)
    assert '[Other](https://paper-chat.fujiy.dev/open?attachment=ABCD1234&page=12)' in rendered
    assert 'https://paperchat.invalid/page/2' in rendered
    code = '`paperchat://open?attachment=ABCD1234`'
    assert citation_links(code) == code
