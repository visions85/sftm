#!/usr/bin/env bash
# Read the SFTM 64-bit In-System Probe over the USB Blaster. Run on gamingpc.
#   ./docker/read-probe.sh [samples] [delay_ms]
#
# Emits one "RAW <64 bits>" line per sample on stdout; decode with
# tools/decode_probe.py. Every meter is in ONE probe word, so a sample is
# internally coherent -- no view mux, no snapshot, nothing to mis-pair.
#
# NOTE: programming the FPGA over JTAG bypasses MiSTer's ROM download, so the
# game will not run. Measure only after a normal MRA load.
set -euo pipefail
N="${1:-600}"; D="${2:-40}"
REPO="${REPO:-/home/david/code/sftm-claude}"
docker run --rm --platform linux/amd64 --privileged \
    -v /dev/bus/usb:/dev/bus/usb -v "${REPO}:/workspace" \
    --entrypoint /bin/bash sftm-quartus -c "
export PATH=/opt/intelFPGA_lite/21.1/quartus/bin:\$PATH
killall jtagd 2>/dev/null || true
jtagd --foreground --config /dev/null >/dev/null 2>&1 &
sleep 3
printf '%s\n' \
'package require ::quartus::stp' \
'set hw \"\"' \
'foreach h [get_hardware_names] { if { [string match \"DE-SoC*\" \$h] } { set hw \$h } }' \
'if { \$hw eq \"\" } { puts \"ERROR: no DE-SoC cable\"; exit 1 }' \
'set dev \"\"' \
'foreach d [get_device_names -hardware_name \$hw] { if { [string match \"*5CSEBA6*\" \$d] } { set dev \$d } }' \
'if { \$dev eq \"\" } { puts \"ERROR: no Cyclone V\"; exit 1 }' \
'catch { end_insystem_source_probe }' \
'start_insystem_source_probe -hardware_name \$hw -device_name \$dev' \
'for { set i 0 } { \$i < ${N} } { incr i } { puts \"RAW0 [read_probe_data -instance_index 0]\"; puts \"RAW1 [read_probe_data -instance_index 1]\"; after ${D} }' \
'end_insystem_source_probe' > /tmp/raw.tcl
quartus_stp -t /tmp/raw.tcl 2>&1 | grep -E '^RAW[01] |^ERROR'
"
