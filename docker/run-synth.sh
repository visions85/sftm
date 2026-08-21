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
# ---- Apply SFTM's jtframe patches ----
# run-synth.sh overrides the image entrypoint below (bash -c 'jtcore ...'), so
# docker/entrypoint.sh -- which is where the jtframe patches live -- NEVER runs
# for a synthesis build. The patches present in the volume got there from a
# previous non-synth container and simply persisted, so any patch added to
# entrypoint.sh was silently ignored here. That cost a build: the debug-overlay
# pin looked applied (clean compile, new .rbf) but the volume still had the
# stock viewmux. Apply them explicitly, in the same container, before jtcore.
echo "[run-synth.sh] Applying jtframe patches..."
docker run --rm --platform linux/amd64 \
    -v "${REPO_DIR}:/workspace" \
    -v "${VOLUME}:/workspace/modules/jtframe" \
    --entrypoint /bin/bash \
    "$IMAGE" -c '
set -e
JTFRAME_DIR=/workspace/modules/jtframe
PATCHES=/workspace/docker/jtframe-patches
[ -d "$PATCHES" ] && cp -r "$PATCHES/." "$JTFRAME_DIR/"
# Pin the debug overlay to the game debug_view -- see entrypoint.sh for why.
sed -i "s/SYS_INFO:    mux <= sys_info;/SYS_INFO:    mux <= debug_view;/" \
    "$JTFRAME_DIR/hdl/debug/jtframe_debug_viewmux.v" || true
sed -i "s/TARGET_INFO: mux <= target_info;/TARGET_INFO: mux <= debug_view;/" \
    "$JTFRAME_DIR/hdl/debug/jtframe_debug_viewmux.v" || true
if grep -q "mux <= sys_info" "$JTFRAME_DIR/hdl/debug/jtframe_debug_viewmux.v"; then
    echo "[sftm] ERROR: debug viewmux pin did NOT apply" >&2; exit 1
fi
echo "[sftm] debug overlay pinned to the game debug_view"
# Plumb SHIFTED through jtframe_burst_sdram. The banks controller path passes
# .SHIFTED(SDRAM_SHIFT) to jtframe_sdram64 -- compensation for the MiSTer PLL
# phase-shifted SDRAM clock -- but jtframe_burst_sdram.v:215 HARDCODES
# .SHIFTED(0). On real hardware every cache-lane burst READ is then captured
# one 16-bit word off, so all fills return shifted content: the instruction
# stream corruption, the wrong initial SP, the interrupt storm and the
# watchdog loop that kept every cache-lanes build from booting. Simulation
# never sees it because there is no clock phase to compensate. The banks build
# (b59) works on the same board because its path passes SHIFTED properly.
grep -q "parameter SHIFTED" "$JTFRAME_DIR/hdl/sdram/jtframe_burst_sdram.v" || \
sed -i "s/module jtframe_burst_sdram #(/module jtframe_burst_sdram #(\n    parameter SHIFTED = 0,/" \
    "$JTFRAME_DIR/hdl/sdram/jtframe_burst_sdram.v" || true
sed -i "s/    .SHIFTED       ( 0        ),/    .SHIFTED       ( SHIFTED  ),/" \
    "$JTFRAME_DIR/hdl/sdram/jtframe_burst_sdram.v" || true
grep -q "SHIFTED    ( SDRAM_SHIFT   )" "$JTFRAME_DIR/hdl/jtframe_board_sdram.v" || \
sed -i "s/    jtframe_burst_sdram #(/    jtframe_burst_sdram #(\n\`ifdef JTFRAME_SDRAM96\n        .SHIFTED    ( 0             ),\n\`else\n        .SHIFTED    ( SDRAM_SHIFT   ),\n\`endif/" \
    "$JTFRAME_DIR/hdl/jtframe_board_sdram.v" || true
if grep -q "SHIFTED       ( 0        )" "$JTFRAME_DIR/hdl/sdram/jtframe_burst_sdram.v"; then
    echo "[sftm] ERROR: SHIFTED plumb did NOT apply" >&2; exit 1
fi
echo "[sftm] SHIFTED plumbed through jtframe_burst_sdram"
# The cache-path bursts are NOT handled by jtframe_sdram64 at all: burst_sdram
# contains its own command FSM, jtframe_burst_ctrl, whose read pipeline is a
# HARDCODED two-wait (B_READ_CMD -> B_CL1 -> B_CL2 -> B_RDATA) with no HF or
# SHIFTED compensation -- while the banks controller carefully derives
# DST = READ + (SHIFTED ? 1 : 2). On real MiSTer (SDRAM clock phase-shifted,
# JTFRAME_SHIFT=1) B_RDATA therefore lands one cycle late and every fill word
# is attributed one position early: measured over JTAG as D = {m[2n+1],
# m[2n+2]} on every lane, which corrupted the instruction stream and kept
# every cache-lanes build from booting. Mirror the banks controller: skip
# B_CL2 when SHIFTED=1.
grep -q "parameter SHIFTED" "$JTFRAME_DIR/hdl/sdram/jtframe_burst_ctrl.v" || \
sed -i "s/module jtframe_burst_ctrl #(/module jtframe_burst_ctrl #(\n    parameter SHIFTED = 0,/" \
    "$JTFRAME_DIR/hdl/sdram/jtframe_burst_ctrl.v" || true
grep -q "SHIFTED==1 ? B_RDATA" "$JTFRAME_DIR/hdl/sdram/jtframe_burst_ctrl.v" || \
sed -i "s/            B_CL1:       burst_st <= B_CL2;/            B_CL1:       burst_st <= (SHIFTED==1 \&\& !post_write_read_wait) ? B_RDATA : B_CL2;/" \
    "$JTFRAME_DIR/hdl/sdram/jtframe_burst_ctrl.v" || true
grep -q "SHIFTED( SHIFTED )" "$JTFRAME_DIR/hdl/sdram/jtframe_burst_sdram.v" || \
sed -i "s/jtframe_burst_ctrl #(/jtframe_burst_ctrl #(\n    .SHIFTED( SHIFTED ),/" \
    "$JTFRAME_DIR/hdl/sdram/jtframe_burst_sdram.v" || true
if ! grep -q "SHIFTED==1 ? B_RDATA" "$JTFRAME_DIR/hdl/sdram/jtframe_burst_ctrl.v"; then
    echo "[sftm] ERROR: burst_ctrl CL patch did NOT apply" >&2; exit 1
fi
echo "[sftm] burst_ctrl read latency compensated (SHIFTED skips B_CL2)"
# SLOT0_ERASE=0 on the bank-3 rw slot -- see entrypoint.sh for why.
sed -i "s/SLOT0_ERASE  = 1,/SLOT0_ERASE  = 0,/" \
    "$JTFRAME_DIR/hdl/sdram/jtframe_ram1_3slots.v" || true
'
PATCH_RC=$?
if [[ $PATCH_RC -ne 0 ]]; then
    echo "[run-synth.sh] jtframe patching FAILED; aborting before synthesis." >&2
    exit $PATCH_RC
fi

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
