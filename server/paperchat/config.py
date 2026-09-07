from __future__ import annotations

from functools import cached_property
from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    data_dir: Path = Field(default=Path("/data"), alias="DATA_DIR")
    database_path: Path | None = Field(default=None, alias="DATABASE_PATH")
    http_host: str = Field(default="0.0.0.0", alias="HTTP_HOST")
    http_port: int = Field(default=8000, alias="HTTP_PORT")
    public_base_url: str = Field(default="http://localhost:8000", alias="PUBLIC_BASE_URL")
    bootstrap_token: SecretStr | None = Field(default=None, alias="BOOTSTRAP_TOKEN")
    bootstrap_token_file: Path | None = Field(default=None, alias="BOOTSTRAP_TOKEN_FILE")
    access_token_ttl_seconds: int = Field(default=3600, alias="ACCESS_TOKEN_TTL_SECONDS")
    refresh_token_ttl_seconds: int = Field(default=2592000, alias="REFRESH_TOKEN_TTL_SECONDS")
    zotero_library_url: str = Field(
        default="http://zotero-library-app:8000", alias="ZOTERO_LIBRARY_URL"
    )
    zotero_mcp_url: str | None = Field(default=None, alias="ZOTERO_MCP_URL")
    zotero_service_token: SecretStr | None = Field(default=None, alias="ZOTERO_SERVICE_TOKEN")
    zotero_service_token_file: Path | None = Field(default=None, alias="ZOTERO_SERVICE_TOKEN_FILE")
    zotero_mcp_token: SecretStr | None = Field(default=None, alias="ZOTERO_MCP_TOKEN")
    zotero_mcp_token_file: Path | None = Field(default=None, alias="ZOTERO_MCP_TOKEN_FILE")
    llm_backend: Literal["fake", "codex"] = Field(default="fake", alias="LLM_BACKEND")
    codex_runner_url: str | None = Field(default=None, alias="CODEX_RUNNER_URL")
    codex_runner_token: SecretStr | None = Field(default=None, alias="CODEX_RUNNER_TOKEN")
    codex_runner_token_file: Path | None = Field(default=None, alias="CODEX_RUNNER_TOKEN_FILE")
    codex_legacy_landlock: bool = Field(default=False, alias="CODEX_LEGACY_LANDLOCK")
    codex_command: str = Field(default="codex", alias="CODEX_COMMAND")
    codex_home: Path = Field(default=Path("/data/codex/home"), alias="CODEX_HOME_DIR")
    codex_workspace: Path = Field(default=Path("/data/codex/workspace"), alias="CODEX_WORKSPACE")
    codex_model: str | None = Field(default=None, alias="CODEX_MODEL")

    @cached_property
    def resolved_database_path(self) -> Path:
        return self.database_path or self.data_dir / "database" / "paperchat.sqlite3"

    def secret(self, value: SecretStr | None, file: Path | None) -> str | None:
        if value and value.get_secret_value():
            return value.get_secret_value()
        if file and file.exists():
            result = file.read_text(encoding="utf-8").strip()
            return result or None
        return None

    @property
    def resolved_bootstrap_token(self) -> str | None:
        return self.secret(self.bootstrap_token, self.bootstrap_token_file)

    @property
    def resolved_zotero_service_token(self) -> str | None:
        return self.secret(self.zotero_service_token, self.zotero_service_token_file)

    @property
    def resolved_zotero_mcp_token(self) -> str | None:
        return self.secret(self.zotero_mcp_token, self.zotero_mcp_token_file)

    @property
    def resolved_zotero_mcp_url(self) -> str:
        return self.zotero_mcp_url or f"{self.zotero_library_url.rstrip('/')}/mcp"

    @property
    def resolved_runner_token(self) -> str | None:
        return self.secret(self.codex_runner_token, self.codex_runner_token_file)

    def ensure_dirs(self) -> None:
        self.resolved_database_path.parent.mkdir(parents=True, exist_ok=True)
        if not self.codex_runner_url:
            self.codex_home.mkdir(parents=True, exist_ok=True)
            self.codex_workspace.mkdir(parents=True, exist_ok=True)


def load_settings() -> Settings:
    return Settings()
