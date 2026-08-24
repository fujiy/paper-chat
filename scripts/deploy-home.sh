#!/bin/sh
set -eu

context="${DOCKER_CONTEXT:-ubuntu}"
old_project_dir="${ZOTERO_PROJECT_DIR:-../zotero-mcp-library}"
zotero_env_file="${ZOTERO_ENV_FILE:-$old_project_dir/.env}"
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

docker_target compose \
  -f "$old_project_dir/compose.yaml" -f "$old_project_dir/compose.prod.yaml" \
  --env-file "$zotero_env_file" down

compose_target up -d --build
compose_target ps
