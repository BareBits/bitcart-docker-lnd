FROM python:3.12-alpine AS base
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

RUN apk add git python3-dev build-base libffi-dev && \
    cd $BTCLND_HOME/site && \
    uv sync --frozen --no-dev --group btclnd --group otel && \
    uv run opentelemetry-bootstrap -a requirements | uv pip install --requirement -

FROM base AS build-image

RUN adduser -D $BTCLND_USER && \
    mkdir -p $BTCLND_DATA_PATH && \
    chown ${BTCLND_USER} $BTCLND_DATA_PATH && \
    mkdir -p $BTCLND_HOME/site && \
    chown ${BTCLND_USER} $BTCLND_HOME/site && \
    apk add --no-cache ca-certificates tor && \
    apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/main jemalloc

COPY --from=compile-image --chown=electrum $BTCLND_HOME/site/.venv $BTCLND_HOME/.venv
COPY --from=compile-image --chown=electrum $BTCLND_HOME/site $BTCLND_HOME/site

ENV PYTHONUNBUFFERED=1 PYTHONMALLOC=malloc LD_PRELOAD=libjemalloc.so.2 MALLOC_CONF=background_thread:true,max_background_threads:1,metadata_thp:auto,dirty_decay_ms:80000,muzzy_decay_ms:80000
ENV PATH="$BTCLND_HOME/.venv/bin:$PATH"
USER $BTCLND_USER
WORKDIR $BTCLND_HOME/site

CMD ["just","daemon", "btclnd"]
