#!/usr/bin/env bash
# First-run setup: vendor jtframe module + build binary, then exec the requested command.
set -euo pipefail

JTFRAME_DIR="/workspace/modules/jtframe"
JTFRAME_BIN="${JTFRAME_DIR}/bin/jtframe"
JTFRAME_SENTINEL="${JTFRAME_DIR}/hdl/include/jtframe.vh"

# ---------------------------------------------------------------------------
# 1. Vendor jtframe module (sparse clone — only runs on first start)
# ---------------------------------------------------------------------------
if [ ! -f "${JTFRAME_SENTINEL}" ]; then
    echo "[sftm] jtframe module not found — sparse-cloning (first run only)..."
    TMP=$(mktemp -d)
    git clone \
        --depth=1 \
        --filter=blob:none \
        --no-checkout \
        https://github.com/jotego/jtcores.git "$TMP"
    cd "$TMP"
    git sparse-checkout init --cone
    git sparse-checkout set modules/jtframe
    git checkout
    mkdir -p "${JTFRAME_DIR}"
    cp -r "$TMP/modules/jtframe/." "${JTFRAME_DIR}/"
    rm -rf "$TMP"
    echo "[sftm] jtframe module vendored to ${JTFRAME_DIR}"
fi

# ---------------------------------------------------------------------------
# 2. Build jtframe Go binary (only if missing or jtframe was just updated)
# ---------------------------------------------------------------------------
if [ ! -f "${JTFRAME_BIN}" ]; then
    echo "[sftm] Building jtframe binary..."
    mkdir -p "${JTFRAME_DIR}/bin"
    cd "${JTFRAME_DIR}/src/jtframe"
    go build -o "${JTFRAME_BIN}" .
    echo "[sftm] jtframe binary ready: ${JTFRAME_BIN}"
fi

# ---------------------------------------------------------------------------
# 3. Exec requested command (default: /bin/bash)
# ---------------------------------------------------------------------------
exec "$@"
