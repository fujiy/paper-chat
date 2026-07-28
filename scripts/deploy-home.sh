#!/bin/sh
set -eu

context="${DOCKER_CONTEXT:-ubuntu}"
old_project_dir="${ZOTERO_PROJECT_DIR:-../zotero-mcp-library}"
volume="${ZOTERO_DATA_VOLUME:-zotero-mcp-library_zotero_data}"

docker --context "$context" volume inspect "$volume" >/dev/null
docker --context "$context" run --rm --mount "type=volume,src=$volume,dst=/data,readonly" \
  alpine:3.22 sh -c 'test -s /data/db/zotero_mcp.sqlite3'

docker --context "$context" compose \
  -f "$old_project_dir/compose.yaml" -f "$old_project_dir/compose.prod.yaml" \
  down

docker --context "$context" compose up -d --build
docker --context "$context" compose ps

