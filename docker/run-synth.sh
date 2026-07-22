#!/usr/bin/env bash
# Run MiSTer synthesis (jtcore sftm -mister) inside the sftm-quartus container.
#
# Prerequisites:
#   1. Build the base image first:   ./docker/run.sh --rebuild
#   2. Build the Quartus image:      docker build -t sftm-quartus \
#                                        -f docker/Dockerfile.quartus docker/
#
# Usage:
#   ./docker/run-synth.sh               # full synthesis (may take ~30 min)
#   ./docker/run-synth.sh --rebuild     # force image rebuild before synthesis
#
# The .rbf output will be at:
#   jtbin/mister/jtsftm.rbf  (or cores/sftm/mister/output_files/jtsftm.rbf)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

IMAGE="sftm-quartus"
BASE_IMAGE="sftm-build"
# Separate volume so the amd64 jtframe binary doesn't collide with the
# ARM64 binary built by the sftm-build (native) container.
VOLUME="jtframe-module-amd64"

# ---- Optionally rebuild the base image ----
if [[ "${1:-}" == "--rebuild" ]]; then
    echo "[run-synth.sh] Rebuilding sftm-build base..."
    docker build -t "$BASE_IMAGE" "$SCRIPT_DIR"
    shift
fi

# ---- Build Quartus image if not present ----
# Must be linux/amd64: Quartus 17.1 is x86_64-only.
# On Apple Silicon this uses Rosetta 2 emulation automatically.
if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "[run-synth.sh] Building Quartus image '$IMAGE' (first time ~30 min)..."
    docker build --platform linux/amd64 -t "$IMAGE" \
        -f "$SCRIPT_DIR/Dockerfile.quartus" "$SCRIPT_DIR"
fi

# ---- Create jtframe volume if needed ----
docker volume inspect "$VOLUME" &>/dev/null \
    || docker volume create "$VOLUME" >/dev/null

# ---- Run synthesis ----
# jtcore is called with -mister target.  The --no-dbg flag keeps macros
# clean; remove it to include OSD debug overlays.
exec docker run --rm -it --platform linux/amd64 \
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
    bash -c 'cd /workspace && jtcore sftm -mister'
