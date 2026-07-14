# syntax=docker/dockerfile:1.7
# ---------- builder ----------
# Use the official uv image (Astral) on top of a slim Python base.
# uv resolves and installs the lockfile-free pyproject.toml in seconds and
# produces a portable .venv we can copy into the runtime stage.
FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim AS builder

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never \
    UV_NO_PROGRESS=1

WORKDIR /app

# Install deps first (separate layer) — script edits won't bust this cache.
COPY pyproject.toml ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --no-dev --no-install-project

# Script is added after the dep layer for cache friendliness.
COPY snrc-resolve.py ./

# ---------- runtime ----------
# Slim runtime — only the venv + script. No uv, no apt.
FROM python:3.13-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/app/.venv/bin:$PATH"

# Non-root user (matches resolver privacy posture: it has no need for root).
RUN groupadd --system --gid 10001 snrc && \
    useradd  --system --uid 10001 --gid snrc --no-create-home --shell /usr/sbin/nologin snrc

WORKDIR /app
COPY --from=builder --chown=snrc:snrc /app /app

USER snrc:snrc

EXPOSE 8000

# Liveness check hits the script's own /health route. ThreadingHTTPServer is
# fast enough that 3s is generous for a localhost probe; restart if it stops
# responding entirely.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request, sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).status == 200 else 1)"]

ENTRYPOINT ["python", "snrc-resolve.py"]
