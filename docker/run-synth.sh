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
# Hit-skip replacement policy arrives as a whole-file overlay from
# jtframe-patches (the insertion contains tick constants, which cannot live
# inside this single-quoted block). Verify it landed.
if ! grep -q "hit-skip replacement" "$JTFRAME_DIR/hdl/sdram/jtframe_cache_ctrl.sv"; then
    echo "[sftm] ERROR: cache hit-skip overlay did NOT apply" >&2; exit 1
fi
if ! grep -q "ghost lookup" "$JTFRAME_DIR/hdl/sdram/jtframe_cache_req.sv"; then
    echo "[sftm] ERROR: cache_req flush overlay did NOT apply" >&2; exit 1
fi
echo "[sftm] cache replacement hit-skip applied (jtframe_cache_ctrl overlay)"
# Pin the debug overlay to the game debug_view -- see entrypoint.sh for why.
sed -i "s/SYS_INFO:    mux <= sys_info;/SYS_INFO:    mux <= debug_view;/" \
    "$JTFRAME_DIR/hdl/debug/jtframe_debug_viewmux.v" || true
sed -i "s/TARGET_INFO: mux <= target_info;/TARGET_INFO: mux <= debug_view;/" \
    "$JTFRAME_DIR/hdl/debug/jtframe_debug_viewmux.v" || true
if grep -q "mux <= sys_info" "$JTFRAME_DIR/hdl/debug/jtframe_debug_viewmux.v"; then
    echo "[sftm] ERROR: debug viewmux pin did NOT apply" >&2; exit 1
fi
echo "[sftm] debug overlay pinned to the game debug_view"
# SDRAM DQ input capture must be in the IO cell, not the fabric. The stock
# mister.qsf template sets FAST_INPUT_REGISTER only on the BANKS controller
# register by hierarchical path (jtframe_sdram_bank...dq_ff) -- a path that
# does not exist in a JTFRAME_SDRAM_CACHE build, so the assignment silently
# applies to nothing, the capture register lands in fabric after long routing,
# and every burst-read word arrives one position early ON SILICON ONLY.
# Measured over JTAG as D = {m[2n+1], m[2n+2]} on every lane; invisible in
# simulation (no placement); and the reason the banks build works on the same
# board while every cache build failed to boot. The header of
# jtframe_burst_io.v describes the intended two-stage pad pipeline and names
# the sys.tcl FAST_OUTPUT_REGISTER assignment; the matching input-side pad
# assignment is what is missing. NOTE: no apostrophes in this block -- it
# lives inside a single-quoted docker -c string and one apostrophe ends it.
grep -q "FAST_INPUT_REGISTER ON -to SDRAM_DQ" "$JTFRAME_DIR/target/mister/mister.qsf" || \
sed -i "s|set_instance_assignment -name FAST_OUTPUT_ENABLE_REGISTER ON -to SDRAM_DQ\[\*\]|set_instance_assignment -name FAST_OUTPUT_ENABLE_REGISTER ON -to SDRAM_DQ[*]\nset_instance_assignment -name FAST_INPUT_REGISTER ON -to SDRAM_DQ[*]\nset_instance_assignment -name FAST_OUTPUT_REGISTER ON -to SDRAM_*|" \
    "$JTFRAME_DIR/target/mister/mister.qsf" || true
if ! grep -q "FAST_INPUT_REGISTER ON -to SDRAM_DQ" "$JTFRAME_DIR/target/mister/mister.qsf"; then
    echo "[sftm] ERROR: SDRAM_DQ pad-register patch did NOT apply" >&2; exit 1
fi
echo "[sftm] SDRAM_DQ pad input register enabled (cache-path capture fix)"
# Compensate the deterministic one-halfword read slip on MiSTer: re-register
# ext_din inside jtframe_cache so the data stream is delayed one clock
# relative to dok. Measured across five independent fits, every fill
# attributes stream word i+1 to position i -- data leads dok by exactly one
# cycle. A one-clock data re-register makes each dok pair with its intended
# word, uniformly and row-safely (an earlier attempt that moved the burst
# START address minus one wrapped within the SDRAM row and destroyed every
# block whose base sits at column zero, vector block included -- readback
# went all-zero). This is the extra data pipeline stage the banks controller
# has and the burst path lacks; sim (which has no slip) intentionally does
# not get this patch.
grep -q "sftm slip reg" "$JTFRAME_DIR/hdl/sdram/jtframe_cache.sv" || \
sed -i "s|( ext_din  *)|( ext_din_r )|" \
    "$JTFRAME_DIR/hdl/sdram/jtframe_cache.sv" || true
grep -q "sftm slip reg" "$JTFRAME_DIR/hdl/sdram/jtframe_cache.sv" || \
sed -i "s|module jtframe_cache #(|// sftm slip reg: ext_din_r declared below the port list\nmodule jtframe_cache #(|" \
    "$JTFRAME_DIR/hdl/sdram/jtframe_cache.sv" || true
grep -q "ext_din_r <= ext_din" "$JTFRAME_DIR/hdl/sdram/jtframe_cache.sv" || \
sed -i "0,/^wire /s//reg [15:0] ext_din_r;\nalways @(posedge clk) ext_din_r <= ext_din;\nwire /" \
    "$JTFRAME_DIR/hdl/sdram/jtframe_cache.sv" || true
if ! grep -q "ext_din_r <= ext_din" "$JTFRAME_DIR/hdl/sdram/jtframe_cache.sv"; then
    echo "[sftm] ERROR: ext_din re-register did NOT apply" >&2; exit 1
fi
echo "[sftm] ext_din one-clock re-register applied (slip compensation v2)"
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
