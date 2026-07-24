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
#   release/mister/sftm.rbf   (Quartus project is named 'sftm')
#   release/mister/jtsftm.rbf (copy created after synthesis for MRA compatibility;
#                               the MRA <rbf> tag uses the JTFRAME jt-prefix name)
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

# ---- Build Quartus image (uses Docker layer cache after first build) ----
# Must be linux/amd64: Quartus 21.1 is x86_64-only.
# On Apple Silicon this uses Rosetta 2 emulation automatically.
# We always call 'docker build' so changed Dockerfiles are picked up;
# unchanged layers are served from cache so subsequent runs are fast.
echo "[run-synth.sh] Building Quartus image '$IMAGE' (cached after first build)..."
docker build --platform linux/amd64 -t "$IMAGE" \
    -f "$SCRIPT_DIR/Dockerfile.quartus" "$SCRIPT_DIR"

# ---- Create jtframe volume if needed ----
docker volume inspect "$VOLUME" &>/dev/null \
    || docker volume create "$VOLUME" >/dev/null

# ---- Run synthesis ----
# jtcore is called with -mister target.  The --no-dbg flag keeps macros
# clean; remove it to include OSD debug overlays.
set +e
docker run --rm --platform linux/amd64 \
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
    bash -c 'git config --global --add safe.directory /workspace && cd /workspace && jtcore sftm -mister'
RC=$?
set -e

# jtcore expects the Quartus project to be named 'jtsftm' but ours is 'sftm',
# so jtcore's own copy step silently fails (it looks for output_files/jtsftm.rbf
# which does not exist).  Promote the Quartus assembler output explicitly.
OUTRBF="${REPO_DIR}/cores/sftm/mister/output_files/sftm.rbf"
if [[ -f "$OUTRBF" ]]; then
    cp "$OUTRBF" "${REPO_DIR}/release/mister/sftm.rbf"
    echo "[run-synth.sh] Promoted output_files/sftm.rbf -> release/mister/sftm.rbf"
fi

# Create the jtsftm.rbf alias expected by the MRA <rbf> tag.
# The Quartus project is named 'sftm' so Quartus outputs sftm.rbf;
# JTFRAME MRA generation uses the jt-prefix convention (jtsftm).
RBF="${REPO_DIR}/release/mister/sftm.rbf"
if [[ -f "$RBF" ]]; then
    cp "$RBF" "${REPO_DIR}/release/mister/jtsftm.rbf"
    echo "[run-synth.sh] Copied sftm.rbf -> jtsftm.rbf"
fi

exit $RC
