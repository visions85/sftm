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
# SLOT0_ERASE=0 on the bank-3 rw slot. jtframe_ram_rq's ERASE walks erase_cnt
# across the slot's ENTIRE address window after reset, writing zeros at
# sdram_addr = erase_cnt + offset. Bank 3 holds vram on slot 0 (offset 0,
# 4 MB window) and grm3 on slot 2, so the erase wiped the grm3 glyph ROM that
# the download had just written -- a real glyph blit read 0x00 as its first
# source byte on hardware. VRAM needs no erase: the game draws a full
# background every frame and never reads VRAM before writing it. mem.yaml
# cannot express this, so patch the default here.
sed -i 's/SLOT0_ERASE  = 1,/SLOT0_ERASE  = 0,/' "${JTFRAME_DIR}/hdl/sdram/jtframe_ram1_3slots.v" 2>/dev/null || true

# Cache-lane offsets: emit VERILOG hex, not C hex.
#
# jtframe mem validates `sdram.cache-lanes[].at.offset` as an 0x... string and
# then interpolates that STRING verbatim into the generated wrapper
# (hdl/inc/game_sdram.v:411), producing `.OFFSET0 ( 0x80000 )`. That is not
# Verilog -- iverilog and Quartus both reject it -- so every cache lane with an
# offset yields an uncompilable file, including the 0x0 ones. Its own unit
# tests only ever cover `( 0 )` and a parameter name, so the hex path was never
# exercised. Rewriting the YAML is not a way out: the validator DEMANDS the
# 0x form and Verilog demands 'h, and the two never overlap.
#
# Normalise after resolve_cache_lane_offset_words() has consumed the original
# string for its range check, so only the emitted text changes. Parameter-name
# offsets do not start with 0x and pass through untouched.
JTMEM="${JTFRAME_DIR}/src/jtframe/mem/mem.go"
if [ -f "${JTMEM}" ] && ! grep -q "sftm: verilog hex" "${JTMEM}"; then
    sed -i "s|^\t\t\toffset_bytes := offset_words << 1$|\t\t\toffset_bytes := offset_words << 1\n\t\t\tif len(line.At.Offset) > 2 \&\& (line.At.Offset[:2] == \"0x\" || line.At.Offset[:2] == \"0X\") { line.At.Offset = \"'h\" + line.At.Offset[2:] } // sftm: verilog hex|" "${JTMEM}"
    if grep -q "sftm: verilog hex" "${JTMEM}"; then
        echo "[sftm] patched jtframe mem.go for Verilog cache-lane offsets"
        rm -f "${JTFRAME_COMPILED}"        # force a rebuild of the binary
    else
        echo "[sftm] WARNING: cache-lane offset patch did not apply" >&2
    fi
fi

# FASTWR is NOT safe on this slot -- left here, disabled, as a warning.
#
# It acks a write when the slot mux grants it, which measured >=122,880
# writes/frame against 65,536 (12.2 -> <=6.5 clk/write) and made a background
# fit inside one frame. But jtframe_ram_rq gates the early ack on
#
#     if( FASTWR && !req_rnw ) data_ok <= 1;
#
# and req_rnw is set when a request is ISSUED, persisting until the next issue.
# So on any grant where the LAST ISSUED request was a write, data_ok is forced
# high whatever the current transaction is: a read following a write gets a
# spurious immediate ack carrying stale dout. FASTWR suits a CPU write-behind
# that only ever writes; our blitter interleaves reads and writes on one slot
# (shiftreg and cmd-3 read back pens they just wrote), so nearly every
# read-modify-write blit is corrupted. Build 63 rendered full-height frames
# with the streaks gone but dense per-pixel speckle, HUD text included.
#
# sed -i 's/...ERASE(SLOT0_ERASE)) u_slot0(/...ERASE(SLOT0_ERASE),.FASTWR(1)) u_slot0(/' jtframe_ram1_3slots.v

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
