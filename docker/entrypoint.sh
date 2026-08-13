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
# 1b. Apply SFTM-specific jtframe patches (idempotent; always applied).
#     Stored in docker/jtframe-patches/ to survive volume re-creation.
# ---------------------------------------------------------------------------
JTFRAME_PATCHES="/workspace/docker/jtframe-patches"
if [ -d "${JTFRAME_PATCHES}" ]; then
    cp -r "${JTFRAME_PATCHES}/." "${JTFRAME_DIR}/"
fi
# GAMMA=0: disable gamma correction LUT tables (~2k ALMs saved; no dedicated macro exists)
sed -i 's/GAMMA=1/GAMMA=0/' "${JTFRAME_DIR}/target/mister/hdl/sys/arcade_video.v" 2>/dev/null || true

# Fitter placement seed. jtcore hardcodes SEED=1 with no flag or env override,
# and Quartus is deterministic, so an identical rebuild reproduces an identical
# result -- rebuilding to chase timing closure is pointless without changing an
# input. This design sits within a few hundred ps on the vendored TG68K
# register file, so the seed is the practical lever. Patch it here, BEFORE
# jtcore generates the QSF: appending to the QSF later fails with "Settings
# File changed outside of the Quartus Prime software" (see the long note in
# jtframe-patches/.../build_id.tcl -- four separate mechanisms were tried).
if [ -n "${JTFRAME_SEED}" ]; then
    sed -i "s/^SEED=.*/SEED=${JTFRAME_SEED}/" "${JTFRAME_DIR}/bin/jtcore"
    echo "[sftm] fitter seed set to ${JTFRAME_SEED}"
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
# 3. Mark /workspace as git-safe (container runs as root; host files are
#    owned by the host user — git 2.35.2+ rejects cross-owner repos).
# ---------------------------------------------------------------------------
git config --global --add safe.directory /workspace

# ---------------------------------------------------------------------------
# 4. Exec requested command (default: /bin/bash)
# ---------------------------------------------------------------------------
exec "$@"
