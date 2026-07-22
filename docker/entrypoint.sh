#!/usr/bin/env bash
# First-run setup: vendor jtframe module + build binary, then exec the requested command.
set -euo pipefail

JTFRAME_DIR="/workspace/modules/jtframe"
# bin/jtframe is a shell wrapper; the actual compiled binary lives in src/jtframe/
JTFRAME_COMPILED="${JTFRAME_DIR}/src/jtframe/jtframe"
JTFRAME_SENTINEL="${JTFRAME_DIR}/src/jtframe/main.go"

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
    cd /workspace  # avoid getcwd error after rmdir
    # Initialise a dummy git repo so jtframe's make_commit_macro() can run
    # git log without panicking (the sparse-clone cp doesn't carry .git).
    git -C "${JTFRAME_DIR}" init -q
    git -C "${JTFRAME_DIR}" config user.email "jtframe@local"
    git -C "${JTFRAME_DIR}" config user.name "jtframe"
    git -C "${JTFRAME_DIR}" add -A
    git -C "${JTFRAME_DIR}" commit -q -m "jtframe snapshot"
    echo "[sftm] jtframe module vendored to ${JTFRAME_DIR}"
fi

# ---------------------------------------------------------------------------
# 2. Pre-compile jtframe binary (bin/jtframe is a wrapper that auto-compiles
#    to src/jtframe/jtframe on first call; we do it here so interactive use
#    is instant rather than waiting ~1 min on first jtframe command)
# ---------------------------------------------------------------------------
if [ ! -f "${JTFRAME_COMPILED}" ]; then
    echo "[sftm] Pre-compiling jtframe binary (~1 min, first run only)..."
    cd "${JTFRAME_DIR}/src/jtframe"
    go build -buildvcs=false .
    echo "[sftm] jtframe binary ready: ${JTFRAME_COMPILED}"
fi

# ---------------------------------------------------------------------------
# 3. Exec requested command (default: /bin/bash)
# ---------------------------------------------------------------------------
exec "$@"
