# syntax=docker/dockerfile:1

# ---- build: resolve dependencies with uv into /app/.venv ----
FROM python:3.12-slim AS build

COPY --from=ghcr.io/astral-sh/uv:0.11 /uv /bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv

WORKDIR /app

# Dependencies first (cached layer), without the project itself.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

# Project source, then install the project into the venv.
COPY README.md alembic.ini ./
COPY alembic ./alembic
COPY app ./app
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-editable


# ---- runtime: no uv, no build tools, non-root ----
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH" \
    RUN_MIGRATIONS=0

RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --home-dir /app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

COPY --from=build --chown=app:app /app/.venv /app/.venv
COPY --from=build --chown=app:app /app/alembic.ini /app/alembic.ini
COPY --from=build --chown=app:app /app/alembic /app/alembic
# The project package itself is installed (non-editable) inside the venv.

# Entrypoint: optionally apply migrations, then exec the command (uvicorn by default).
COPY --chmod=0755 <<'SCRIPT' /usr/local/bin/docker-entrypoint.sh
#!/bin/sh
set -eu
if [ "${RUN_MIGRATIONS:-0}" = "1" ]; then
    echo "entrypoint: running alembic upgrade head"
    alembic -c /app/alembic.ini upgrade head
fi
exec "$@"
SCRIPT

USER app

EXPOSE 8000

# slim has no curl: probe liveness with the stdlib.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=4).status == 200 else 1)"]

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
