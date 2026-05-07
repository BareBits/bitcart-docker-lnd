#!/usr/bin/env bash
# Build bitcart, bitcart-admin and per-coin daemon images from custom git
# sources, tagging them with the same names the generated compose file
# already references (bitcart/bitcart:stable, etc.) so the existing flow
# in helpers.sh / start.sh consumes them transparently.
#
# Driven by env vars (typically set in deploy.sh or the user shell):
#   BITCART_REPO_URL          (default: https://github.com/bitcart/bitcart.git)
#   BITCART_REPO_BRANCH       (default: master)
#   BITCART_ADMIN_REPO_URL    (default: https://github.com/bitcart/bitcart-admin.git)
#   BITCART_ADMIN_REPO_BRANCH (default: master)
#   BITCART_CRYPTOS           comma-separated, e.g. "btc,btclnd". Determines
#                             which coin daemon images get built. For each
#                             entry <coin>, this script expects a
#                             compose/<coin>.Dockerfile to exist.
#
# Idempotent: existing clones are git-pulled instead of re-cloned.

set -euo pipefail

: "${BITCART_REPO_URL:=https://github.com/bitcart/bitcart.git}"
: "${BITCART_REPO_BRANCH:=master}"
: "${BITCART_ADMIN_REPO_URL:=https://github.com/bitcart/bitcart-admin.git}"
: "${BITCART_ADMIN_REPO_BRANCH:=master}"
: "${BITCART_CRYPTOS:=btc}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$ROOT_DIR/src"
mkdir -p "$SRC_DIR"

clone_or_pull() {
    local url="$1" branch="$2" dest="$3"
    if [ -d "$dest/.git" ]; then
        echo "==> Updating $dest ($branch)"
        git -C "$dest" remote set-url origin "$url"
        git -C "$dest" fetch --depth=1 origin "$branch"
        git -C "$dest" checkout -B "$branch" "origin/$branch"
    else
        echo "==> Cloning $url@$branch -> $dest"
        rm -rf "$dest"
        git clone --depth=1 --branch "$branch" "$url" "$dest"
    fi
}

clone_or_pull "$BITCART_REPO_URL"       "$BITCART_REPO_BRANCH"       "$SRC_DIR/bitcart"
clone_or_pull "$BITCART_ADMIN_REPO_URL" "$BITCART_ADMIN_REPO_BRANCH" "$SRC_DIR/bitcart-admin"

# Backend + coin Dockerfiles do `COPY bitcart /app` and `COPY scripts/...`,
# so the build context must contain BOTH a `bitcart/` directory (the source
# clone) AND a `scripts/` directory (the helper scripts shipped here in
# compose/scripts/). We stage both into a temp dir per build run.
STAGING_DIR="$(mktemp -d -t bitcart-build-XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT

echo "==> Staging backend/coin build context at $STAGING_DIR"
# rsync trims the .git directory and any local venv to keep the context small
rsync -a --delete --exclude=.git --exclude=.venv --exclude=__pycache__ \
    "$SRC_DIR/bitcart/" "$STAGING_DIR/bitcart/"
cp -r "$ROOT_DIR/compose/scripts" "$STAGING_DIR/scripts"

echo "==> Building bitcart/bitcart:stable (backend + worker image)"
docker build \
    -t bitcart/bitcart:stable \
    -f "$ROOT_DIR/compose/backend.Dockerfile" \
    "$STAGING_DIR"

# Per-coin daemon images. Each <coin> in BITCART_CRYPTOS maps to
# compose/<coin>.Dockerfile and image bitcart/bitcart-<coin>:stable.
IFS=',' read -r -a coins <<<"$BITCART_CRYPTOS"
for coin in "${coins[@]}"; do
    coin="${coin// /}"
    [ -z "$coin" ] && continue
    dockerfile="$ROOT_DIR/compose/${coin}.Dockerfile"
    if [ ! -f "$dockerfile" ]; then
        echo "!! No $dockerfile — skipping coin '$coin'." >&2
        continue
    fi
    echo "==> Building bitcart/bitcart-${coin}:stable"
    docker build \
        -t "bitcart/bitcart-${coin}:stable" \
        -f "$dockerfile" \
        "$STAGING_DIR"
done

echo "==> Building bitcart/bitcart-admin:stable"
docker build \
    -t bitcart/bitcart-admin:stable \
    "$SRC_DIR/bitcart-admin"

echo "==> Custom image build complete."
