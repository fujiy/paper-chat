# PaperChat

PaperChat is a private, self-hosted PDF reading and conversation workspace for
macOS, iPadOS, and iOS. It keeps Zotero as the source of record, persists
per-paper chat threads and reading positions, and streams answers through a
replaceable LLM backend.

See [README_JP.md](README_JP.md) for setup, deployment, and verification
instructions. The product and architecture scope is documented in
[initial_design.md](initial_design.md).

## Zotero REST API verification

The sibling Zotero service exposes its single personal library at `/api/v1`.
Its `/admin/access` page manages script tokens and the Zotero API-key connection;
see the sibling repository's `docs/rest-api.md` for setup and endpoint details.
The app receives the existing `ZOTERO_API_KEY` fallback so upstream REST reads work
before a key is saved in the UI. Managed key settings in the shared volume override
this environment key.

After `./scripts/deploy-home.sh`, run the REST smoke check inside the Zotero app:

```sh
docker --context "${DOCKER_CONTEXT:-ubuntu}" compose exec -T zotero-library-app python - \
  < scripts/zotero-rest-smoke-test.py
```

When using `DOCKER_HOST_URL`, use `DOCKER_HOST="$DOCKER_HOST_URL" docker compose ...`
instead of `--context`. The check creates and revokes its own temporary API token,
reads metadata/search/page text and a PDF range, and verifies existing MCP access.
It prints no credentials or library content. Add `--public` after `python -` to
repeat these checks through the configured public HTTPS URL. Zotero keys can be
validated and saved directly in the admin UI; no OAuth app registration is needed.


### Management chats and the Codex runner

Open **Chats → New Management Chat** to start a conversation without a paper.
Management chats can install skills, local dependencies, and MCP integrations in
Codex's persistent environment. Ask for a repository and the intended setup in
ordinary language. No particular skill is bundled or special-cased.
New clients request `/api/chats?include_management=true`; the default list stays
paper-only so older clients can still decode their existing chats. Installed
skills and MCP configuration are loaded again on the next message, including
when an existing conversation is resumed. Paper chats may read skill references
and use their installed tools; package installation belongs in management chats.

`paperchat-api` calls the authenticated internal `codex-runner` HTTP service; the
API image no longer contains Codex. The runner has no published port, runs as a
non-root user with a read-only container root, and mounts only its own Codex data
and runner/Zotero-MCP credentials. It has no API database, API bootstrap token,
Zotero REST service token, host directory, or Docker socket mount. Management
commands have write/network access inside this container, including its Codex
authentication and configuration. Registered PaperChat devices are trusted to
create management chats. This is not a multi-tenant administration boundary.

`CODEX_RUNNER_URL` and `CODEX_RUNNER_TOKEN_FILE` configure the API transport.
The runner uses `CODEX_HOME_DIR`, `CODEX_WORKSPACE`, and `CODEX_MODEL`.
User MCP entries in `config.toml` are preserved alongside the built-in Zotero
connection. Tool/configuration changes are refreshed by starting an app-server
process for every message. Interactive approval requests are not supported;
management access is limited by the dedicated container, while paper turns use
the Codex read-only sandbox. Compose enables `CODEX_LEGACY_LANDLOCK` for
Codex 0.145.0 so read-only commands work on Docker hosts that prohibit nested
user namespaces. This retains filesystem write denial without granting Docker
capabilities or disabling its seccomp policy. Set it to `false` on hosts that
support the newer sandbox; verify sandbox behavior when upgrading Codex.

`./scripts/deploy-home.sh` migrates the former `/data/codex` directory from the
API volume into `CODEX_DATA_VOLUME` (default `paperchat_codex_data`), compares the
copy, and removes the old directory from the API volume. Existing authentication
and backend thread IDs are preserved. It also provisions `CODEX_SECRETS_VOLUME`
(default `paperchat_codex_secrets`) separately. The legacy API volume defaults to
`paperchat_paperchat_data`; set `PAPERCHAT_DATA_VOLUME` if its name differs. Never
remove these volumes during deployment. To sign in again, run `codex login
--device-auth` in `codex-runner`, not `paperchat-api`.

For an end-to-end check, pipe `scripts/chat-smoke-test.py` into `python -` in the
API container with `--prompt '...'`. Reuse the printed ID with `--thread-id` for a
follow-up. The script checks SSE completion and persisted answers and revokes
its temporary API session; the management conversation remains in Chats.
