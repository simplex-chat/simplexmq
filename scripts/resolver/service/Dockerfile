# syntax=docker/dockerfile:1.7
# ---------- builder ----------
# The official uv image (Astral) on top of a slim Python base installs the
# locked dependencies and the resolver into a portable .venv for the runtime stage.
# Pinned to the uv that wrote uv.lock (its bookworm images stopped at 0.9.30), on the
# runtime's Debian release, so the .venv's Python path exists there.
FROM ghcr.io/astral-sh/uv:0.12.16-python3.13-trixie-slim AS builder

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never \
    UV_NO_PROGRESS=1

WORKDIR /app

# Dependencies first (separate layer), exactly as locked: source edits don't bust this cache.
COPY pyproject.toml uv.lock .python-version ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

# The resolver itself, installed into the .venv rather than linked to /app/src.
COPY src ./src
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-editable

# ---------- runtime ----------
# Slim runtime — only the venv. No uv, no sources, no apt.
FROM python:3.13-slim-trixie AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/app/.venv/bin:$PATH"

# Non-root user (matches resolver privacy posture: it has no need for root).
RUN groupadd --system --gid 10001 snrc && \
    useradd  --system --uid 10001 --gid snrc --no-create-home --shell /usr/sbin/nologin snrc

WORKDIR /app
# owned by root, so the service cannot rewrite its own code
COPY --from=builder /app/.venv /app/.venv

USER snrc:snrc

EXPOSE 8000

# Liveness check hits the resolver's own /health route. Three failures mark the
# container unhealthy; compose does not restart it for that, but `docker ps` shows it.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request, sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).status == 200 else 1)"]

ENTRYPOINT ["snrc-resolve"]
