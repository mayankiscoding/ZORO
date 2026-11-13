# syntax=docker/dockerfile:1
# Build context: ./backend. Not built on the development Mac (no Docker there).
FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

RUN useradd --system --create-home --uid 10001 zoro \
    && mkdir -p /srv/backend /srv/data /opt/venv \
    && chown -R zoro:zoro /srv /opt/venv
USER zoro
WORKDIR /srv/backend

# Dependencies first for layer caching.
COPY --chown=zoro:zoro pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --extra redis --extra objectstore

COPY --chown=zoro:zoro app ./app

ENV ZORO_OBJECT_DIR=/srv/data/objects
EXPOSE 8787
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8787"]
