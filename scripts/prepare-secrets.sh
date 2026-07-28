#!/bin/sh
set -eu

mkdir -p .secrets
chmod 700 .secrets

for name in paperchat_bootstrap_token zotero_service_token; do
  path=".secrets/$name"
  if [ ! -s "$path" ]; then
    umask 077
    openssl rand -base64 36 > "$path"
  fi
done

echo "Secrets are ready in .secrets/ (git-ignored)."

