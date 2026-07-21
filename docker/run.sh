#!/usr/bin/env bash
# Build (if needed) and run the sftm Linux environment container.
#
# Usage:
#   ./docker/run.sh                   # interactive shell
#   ./docker/run.sh iverilog --version
#   ./docker/run.sh jtframe mem sftm
#   ./docker/run.sh bash -c "cd /workspace/cores/sftm && iverilog ..."
#
# On first run the entrypoint sparse-clones jtframe (~50 MB) and builds
# the jtframe Go binary. Subsequent starts skip both steps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

IMAGE="sftm-build"
VOLUME="jtframe-module"

# ---- Build image if not present (or pass --rebuild to force) ----
REBUILD=0
if [[ "${1:-}" == "--rebuild" ]]; then
    REBUILD=1
    shift
fi

if [[ $REBUILD -eq 1 ]] || ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "[run.sh] Building Docker image '$IMAGE'..."
    docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

# ---- Create named volume if it doesn't exist ----
docker volume inspect "$VOLUME" &>/dev/null \
    || docker volume create "$VOLUME" >/dev/null

# ---- Run ----
exec docker run --rm -it \
    -v "${REPO_DIR}:/workspace" \
    -v "${VOLUME}:/workspace/modules/jtframe" \
    -e JTROOT=/workspace \
    -e JTFRAME=/workspace/modules/jtframe \
    -e CORES=/workspace/cores \
    -e MODULES=/workspace/modules \
    -e JTBIN=/workspace/jtbin \
    -e ROM=/workspace/rom \
    -e MRA=/workspace/jtbin/mra \
    -e TARGET=mister \
    "$IMAGE" \
    "${@:-/bin/bash}"
