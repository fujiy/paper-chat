FROM node:24-bookworm-slim AS codex
ARG CODEX_VERSION=0.146.0-alpha.3
RUN npm install --global "@openai/codex@${CODEX_VERSION}"

FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy
RUN useradd --create-home --uid 10001 paperchat
COPY --from=codex /usr/local/bin/node /usr/local/bin/node
COPY --from=codex /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex
WORKDIR /app
COPY pyproject.toml uv.lock ./
COPY server ./server
RUN uv sync --frozen --no-dev
RUN mkdir -p /data && chown -R paperchat:paperchat /data /app
USER paperchat
ENV PATH="/app/.venv/bin:${PATH}"
EXPOSE 8000
CMD ["paperchat-api"]
