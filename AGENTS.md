# PaperChat repository instructions

## Server changes

- Changes under `server/`, `Dockerfile`, `compose.yaml`, or server-facing deployment scripts are not complete at local implementation alone. Unless the user explicitly asks not to deploy, carry the work through deployment to the configured home server.
- Before deployment, run the relevant server tests. For ordinary Python API changes, the minimum verification is:
  - `.venv/bin/ruff check server`
  - `.venv/bin/pytest -q`
- Deploy with `./scripts/deploy-home.sh`. The script defaults to the `ubuntu` Docker context; honor `DOCKER_CONTEXT`, `DOCKER_HOST_URL`, and the other documented environment overrides when they are already set or the user specifies them.
- Never add `--volumes` to Compose teardown commands. The deployment intentionally preserves and reuses the Zotero and PaperChat named volumes.
- After deployment, verify that Compose reports the services as running and check the PaperChat API health endpoint through the deployed Docker context. Run a broader smoke test when the change affects authentication, Zotero integration, PDF delivery, chat streaming, or persistence paths covered by `scripts/smoke-test.py`.
- If deployment cannot be performed because the configured host, Docker context, credentials, or required secrets are unavailable, report that explicitly as the remaining blocker; do not describe the server change as fully complete.
