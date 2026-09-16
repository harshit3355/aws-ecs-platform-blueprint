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
# one directory and inherit none of the wheel cache or the build toolchain.
#
# pip and setuptools are then deleted from the virtualenv itself. Nothing at
# runtime installs packages, and they are not inert: pip vendors its own copies
# of several libraries, so a scanner reads that whole vendored tree as installed
# dependencies. msgpack GHSA-6v7p-g79w-8964 was reported against this image and
# is reachable only through pip's vendored cachecontrol -- code the container
# never executes. Removing the installer removes the entire class of finding,
# and takes a package installer out of a running container besides.
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip setuptools \
    && /opt/venv/bin/pip install -r requirements.txt \
    && find /opt/venv -depth \
         \( -name "pip" -o -name "pip-*" -o -name "pip.*" \
            -o -name "setuptools" -o -name "setuptools-*" \
            -o -name "pkg_resources" -o -name "_distutils_hack*" \) \
         -exec rm -rf {} +

# ---------- runtime ----------
FROM ${PYTHON_IMAGE} AS runtime

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Apply OS security updates, strip the system build toolchain, then create the
# unprivileged user.
#
# The base image is pinned by digest, which fixes the starting point but also
# freezes whatever CVEs that layer shipped with. Scanning this image found 12
# fixable HIGH/CRITICAL vulnerabilities in Debian packages the base has not been
# rebuilt to include. Upgrading here applies those fixes at build time.
#
# The trade-off is deliberate: two builds from the same digest can now differ in
# their OS package versions, so the layer is reproducible but not bit-identical
# over time. That is the right way round -- the alternative is a bit-identical
# image with known, fixed, unpatched vulnerabilities. The image is scanned after
# this step, so a regression still fails the build.
#
# System pip and setuptools are removed as well. The application runs from
# /opt/venv and never uses the interpreter's own site-packages, but the copy of
# setuptools the base image ships carries CVE-2025-47273 and is what the scanner
# reports -- pinning setuptools in requirements.txt fixes the venv and leaves
# this one untouched. Removing it also takes a package installer out of a
# running container, which is worth doing on its own.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && find /usr/local -depth \
         \( -name "setuptools*" -o -name "pkg_resources*" -o -name "pip*" \) \
         -exec rm -rf {} + \
    && groupadd --system --gid 10001 app \
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
