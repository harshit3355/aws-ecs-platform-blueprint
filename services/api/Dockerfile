# syntax=docker/dockerfile:1

# Base image pinned by digest, not just by tag. A tag is mutable; a digest is the
# only thing that makes "the image CI scanned" and "the image production runs"
# provably identical. Tag is kept alongside it for human readability.
ARG PYTHON_IMAGE=python:3.14.7-slim-trixie@sha256:cad9a2c871761c413caa6fdd6441c783451e740a48aaeba60ae62a8b53525ef6

# ---------- build ----------
FROM ${PYTHON_IMAGE} AS build

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build
COPY requirements.txt .

# Dependencies go into their own virtualenv so the runtime stage can copy exactly
# one directory and inherit none of pip, the wheel cache, or the build toolchain.
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --require-hashes=false -r requirements.txt

# ---------- runtime ----------
FROM ${PYTHON_IMAGE} AS runtime

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Non-root, no shell, no home. Nothing in the image needs to write to disk.
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=build /opt/venv /opt/venv

WORKDIR /srv
COPY --chown=app:app *.py ./

USER 10001:10001
EXPOSE 8000

# Container-level liveness. The ALB target group checks the same path, but this
# also makes `docker compose ps` and ECS container health meaningful.
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status == 200 else 1)"

# --proxy-headers so X-Forwarded-For from the ALB is honoured in access logs
# instead of every request appearing to come from the load balancer's ENI.
CMD ["uvicorn", "main:app", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--proxy-headers", \
     "--forwarded-allow-ips", "*", \
     "--no-server-header"]
