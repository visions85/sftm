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
#
# The 'jt' prefix belongs to JOTEGO's own cores, so this core ships as 'sftm'.
# JTFRAME's generators hardcode that prefix in two places -- the MRA <rbf> tag
# and the generated wrapper module name -- so the tag is rewritten below and
# the wrapper keeps its generated name (it is internal and never user-visible).
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
# The installers (docker/quartus-installers/*.run/.qdz) are gitignored and
# may be absent on a machine that already has the image built -- in that
# case reuse the existing image instead of failing the COPY step.
if [[ -f "$SCRIPT_DIR/quartus-installers/QuartusLiteSetup-21.1.0.842-linux.run" ]] \
   || ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "[run-synth.sh] Building Quartus image '$IMAGE' (cached after first build)..."
    docker build --platform linux/amd64 -t "$IMAGE" \
        -f "$SCRIPT_DIR/Dockerfile.quartus" "$SCRIPT_DIR"
else
    echo "[run-synth.sh] Installers absent; reusing existing '$IMAGE' image."
fi

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
    -e JTFRAME_SEED="${JTFRAME_SEED:-}" \
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

# Point any generated MRA at 'sftm' rather than JTFRAME's jt-prefixed default.
for MRA in "${REPO_DIR}"/release/mra/*.mra; do
    [[ -f "$MRA" ]] || continue
    if grep -q "<rbf>jtsftm</rbf>" "$MRA"; then
        sed -i.bak 's|<rbf>jtsftm</rbf>|<rbf>sftm</rbf>|' "$MRA" && rm -f "$MRA.bak"
        echo "[run-synth.sh] MRA <rbf> tag set to sftm: $(basename "$MRA")"
    fi
done

exit $RC
