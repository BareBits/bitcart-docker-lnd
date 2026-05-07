FROM python:3.12-slim-trixie AS base
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV BTCLND_USER=electrum
ENV BTCLND_HOME=/home/$BTCLND_USER
ENV BTCLND_DATA_PATH=/data
ENV IN_DOCKER=1
ENV UV_COMPILE_BYTECODE=1
ENV UV_NO_CACHE=1
ENV UV_NO_SYNC=1
ENV BTCLND_HOST=0.0.0.0
LABEL org.bitcart.image=btclnd-daemon

FROM base AS compile-image

COPY bitcart $BTCLND_HOME/site

RUN apt-get update && \
    apt-get install -y --no-install-recommends git build-essential python3-dev libffi-dev ca-certificates && \
    cd $BTCLND_HOME/site && \
    uv sync --frozen --no-dev --group btclnd --group otel && \
    uv run opentelemetry-bootstrap -a requirements | uv pip install --requirement - && \
    rm -rf /var/lib/apt/lists/*

FROM base AS build-image

# Runtime deps:
# - curl: LNDBinaryManager downloads the lnd release tarball via curl
# - tor: enables hybrid-mode operation (daemon auto-detects via shutil.which)
# - ca-certificates: HTTPS to github releases and any clearnet peers
# - libjemalloc2: matches the backend image's memory allocator setup
RUN useradd --uid 1000 --shell /bin/bash --create-home $BTCLND_USER && \
    mkdir -p $BTCLND_DATA_PATH && \
    chown $BTCLND_USER $BTCLND_DATA_PATH && \
    apt-get update && \
    apt-get install -y --no-install-recommends curl tor ca-certificates libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=compile-image --chown=electrum $BTCLND_HOME/site/.venv $BTCLND_HOME/.venv
COPY --from=compile-image --chown=electrum $BTCLND_HOME/site $BTCLND_HOME/site

ENV PYTHONUNBUFFERED=1 PYTHONMALLOC=malloc LD_PRELOAD=libjemalloc.so.2 MALLOC_CONF=background_thread:true,max_background_threads:1,metadata_thp:auto,dirty_decay_ms:80000,muzzy_decay_ms:80000
ENV PATH="$BTCLND_HOME/.venv/bin:$PATH"
USER $BTCLND_USER
WORKDIR $BTCLND_HOME/site

CMD ["just","daemon", "btclnd"]
