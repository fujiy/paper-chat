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
