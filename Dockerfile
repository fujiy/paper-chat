FROM node:24-bookworm-slim AS codex
ARG CODEX_VERSION=0.145.0
RUN npm install --global "@openai/codex@${CODEX_VERSION}"

FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy
RUN useradd --create-home --uid 10001 paperchat
WORKDIR /app
COPY pyproject.toml uv.lock ./
COPY server ./server
RUN uv sync --frozen --no-dev
RUN mkdir -p /data && chown -R paperchat:paperchat /data
USER paperchat
ENV PATH="/app/.venv/bin:${PATH}"
EXPOSE 8000
CMD ["paperchat-api"]

FROM runtime AS runner
USER root
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=codex /usr/local/bin/node /usr/local/bin/node
COPY --from=codex /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex \
    && ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
USER paperchat
ENV HOME="/data/codex" CODEX_HOME="/data/codex/home"
CMD ["uvicorn", "paperchat.runner:app", "--host", "0.0.0.0", "--port", "8000"]

FROM runtime AS test
USER root
RUN uv sync --frozen
USER paperchat
CMD ["/app/.venv/bin/pytest"]
