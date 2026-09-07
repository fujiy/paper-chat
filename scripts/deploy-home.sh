#!/bin/sh
set -eu

context="${DOCKER_CONTEXT:-ubuntu}"
zotero_project_dir="${ZOTERO_PROJECT_DIR:-./services/zotero-search}"
legacy_project="${ZOTERO_LEGACY_COMPOSE_PROJECT:-zotero-mcp-library}"
zotero_env_file="${ZOTERO_ENV_FILE:-$zotero_project_dir/.env}"
paperchat_env_file="${PAPERCHAT_ENV_FILE:-.env}"
volume="${ZOTERO_DATA_VOLUME:-zotero-mcp-library_zotero_data}"
secrets_volume="${PAPERCHAT_SECRETS_VOLUME:-paperchat_secrets}"

if [ -n "${DOCKER_HOST_URL:-}" ]; then
  export DOCKER_HOST="$DOCKER_HOST_URL"
  docker_context_args=""
else
  docker_context_args="--context $context"
fi

docker_target() {
  # Intentional word splitting: docker_context_args is either empty or "--context NAME".
  docker $docker_context_args "$@"
}

compose_target() {
  if [ -f "$paperchat_env_file" ]; then
    docker_target compose --env-file "$zotero_env_file" --env-file "$paperchat_env_file" "$@"
  else
    docker_target compose --env-file "$zotero_env_file" "$@"
  fi
}

./scripts/prepare-secrets.sh
test -s "$zotero_env_file"

# Finish image builds before stopping services for the one-time data migration.
compose_target build

docker_target volume inspect "$volume" >/dev/null
docker_target run --rm --mount "type=volume,src=$volume,dst=/data,readonly" \
  alpine:3.22 sh -c 'test -s /data/db/zotero_mcp.sqlite3'

docker_target volume create "$secrets_volume" >/dev/null
docker_target run --rm -i --mount "type=volume,src=$secrets_volume,dst=/secrets" \
  alpine:3.22 sh -c \
  'umask 077; cat > /secrets/paperchat_bootstrap_token; chown 10001:10001 /secrets/paperchat_bootstrap_token' \
  < .secrets/paperchat_bootstrap_token
docker_target run --rm -i --mount "type=volume,src=$secrets_volume,dst=/secrets" \
  alpine:3.22 sh -c \
  'umask 077; cat > /secrets/zotero_service_token; chown 10001:10001 /secrets/zotero_service_token' \
  < .secrets/zotero_service_token
docker_target run --rm -i --mount "type=volume,src=$secrets_volume,dst=/secrets" \
  alpine:3.22 sh -c \
  'umask 077; cat > /secrets/zotero_mcp_token; chown 10001:10001 /secrets/zotero_mcp_token' \
  < .secrets/zotero_mcp_token

# Keep runner credentials separate: it never receives the API bootstrap/service tokens.
codex_volume="${CODEX_DATA_VOLUME:-paperchat_codex_data}"
codex_secrets="${CODEX_SECRETS_VOLUME:-paperchat_codex_secrets}"
api_volume="${PAPERCHAT_DATA_VOLUME:-paperchat_paperchat_data}"
docker_target volume create "$codex_volume" >/dev/null
docker_target volume create "$codex_secrets" >/dev/null
docker_target run --rm \
  --mount "type=volume,src=$secrets_volume,dst=/api-secrets" \
  --mount "type=volume,src=$codex_secrets,dst=/runner-secrets" \
  alpine:3.22 sh -eu -c '
    umask 077
    if [ ! -s /api-secrets/codex_runner_token ]; then
      head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n" > /api-secrets/codex_runner_token
    fi
    cp /api-secrets/codex_runner_token /runner-secrets/codex_runner_token
    cp /api-secrets/zotero_mcp_token /runner-secrets/zotero_mcp_token
    chown -R 10001:10001 /runner-secrets
    chown 10001:10001 /api-secrets/codex_runner_token
  '

# Stop the old API before copying live Codex sessions. Compare the copy before
# removing the old directory, so credentials no longer reside in the API volume.
if docker_target volume inspect "$api_volume" >/dev/null 2>&1; then
  compose_target stop paperchat-api codex-runner
  docker_target run --rm \
    --mount "type=volume,src=$api_volume,dst=/api-data" \
    --mount "type=volume,src=$codex_volume,dst=/runner-data" \
    alpine:3.22 sh -eu -c '
      if [ -d /api-data/codex ] && [ ! -e /runner-data/.migrated ]; then
        cp -a /api-data/codex/. /runner-data/
        diff -qr /api-data/codex /runner-data
        touch /runner-data/.migrated
        rm -rf /api-data/codex
      fi
      chown -R 10001:10001 /runner-data
    '
else
  docker_target run --rm --mount "type=volume,src=$codex_volume,dst=/runner-data" \
    alpine:3.22 chown 10001:10001 /runner-data
fi

docker_target compose -p "$legacy_project" \
  -f "$zotero_project_dir/compose.yaml" -f "$zotero_project_dir/compose.prod.yaml" \
  --env-file "$zotero_env_file" down

compose_target up -d --no-build
compose_target ps
