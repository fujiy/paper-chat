from paperchat.config import Settings
from paperchat.llm import CodexBackend


def test_codex_backend_configures_internal_zotero_mcp(tmp_path):
    settings = Settings(
        DATA_DIR=tmp_path,
        ZOTERO_LIBRARY_URL="http://zotero-library-app:8000",
        ZOTERO_SERVICE_TOKEN="library-secret",
        ZOTERO_MCP_TOKEN="mcp-secret",
        CODEX_HOME_DIR=tmp_path / "codex-home",
        CODEX_WORKSPACE=tmp_path / "codex-workspace",
        _env_file=None,
    )
    backend = CodexBackend(settings)

    env = backend.app_server_env()
    config = backend.mcp_config_override()

    assert env[backend.MCP_TOKEN_ENV_VAR] == "mcp-secret"
    assert "http://zotero-library-app:8000/mcp" in config
    assert backend.MCP_TOKEN_ENV_VAR in config
    assert "mcp-secret" not in config
    assert "enabled_tools" not in config


def test_codex_instructions_allow_other_zotero_papers():
    instructions = CodexBackend.developer_instructions()

    assert "any tool from the zotero_library MCP server" in instructions
    assert "including searching and reading other papers" in instructions
    assert "brief commentary updates" in instructions


def test_codex_resume_excludes_turn_history(tmp_path):
    settings = Settings(
        DATA_DIR=tmp_path,
        CODEX_HOME_DIR=tmp_path / "codex-home",
        CODEX_WORKSPACE=tmp_path / "codex-workspace",
        _env_file=None,
    )
    backend = CodexBackend(settings)

    assert backend.initialize_params()["capabilities"]["experimentalApi"] is True
    assert backend.thread_resume_params("thread-123") == {
        "threadId": "thread-123",
        "cwd": str(settings.codex_workspace),
        "approvalPolicy": "never",
        "sandbox": "read-only",
        "developerInstructions": backend.developer_instructions(),
        "excludeTurns": True,
    }


def test_codex_app_server_stream_limit_handles_large_json_lines():
    assert CodexBackend.APP_SERVER_STREAM_LIMIT >= 8 * 1024 * 1024


def test_codex_progress_event_maps_tool_lifecycle():
    started = CodexBackend.progress_event(
        {
            "id": "tool-1",
            "type": "mcpToolCall",
            "server": "zotero_library",
            "tool": "search",
            "status": "inProgress",
        },
        completed=False,
    )
    completed = CodexBackend.progress_event(
        {
            "id": "tool-1",
            "type": "mcpToolCall",
            "server": "zotero_library",
            "tool": "search",
            "status": "completed",
        },
        completed=True,
    )

    assert started is not None
    assert started.progress_title == "zotero_library: search"
    assert started.progress_status == "running"
    assert completed is not None
    assert completed.progress_status == "completed"


def test_codex_progress_event_only_maps_commentary_agent_messages():
    commentary = CodexBackend.progress_event(
        {
            "id": "message-1",
            "type": "agentMessage",
            "phase": "commentary",
            "text": "Searching related papers.",
        },
        completed=True,
    )
    final_answer = CodexBackend.progress_event(
        {
            "id": "message-2",
            "type": "agentMessage",
            "phase": "final_answer",
            "text": "The result is...",
        },
        completed=True,
    )

    assert commentary is not None
    assert commentary.text == "Searching related papers."
    assert final_answer is None
