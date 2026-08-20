#!/usr/bin/env bash
# Push the SFTM program ROM into SDRAM over JTAG, then release the CPU.
#
#   ./docker/load-rom-jtag.sh <prog.bin> [words]
#
# Needed because the SLD hub is only reachable when the FPGA is configured from
# the .sof over JTAG, and that path skips MiSTer's ROM download -- and SDRAM
# does not survive the ~3 s configure (first longword read 0x00808000 vs
# 0x00008000, one bit out, stable: retention decay).
#
# Writes through the `main` cache lane, which mem.yaml now declares rw, so the
# CPU reads back exactly what we wrote with no flush needed.
# Measured ISSP throughput ~8,600 writes/s => 1 MB (262,144 words) ~30 s.
set -euo pipefail
BIN="${1:?usage: load-rom-jtag.sh <prog.bin> [words]}"
WORDS="${2:-0}"     # 0 = whole file
docker run --rm --platform linux/amd64 --privileged \
    -v /dev/bus/usb:/dev/bus/usb -v /home/david/code/sftm-claude:/workspace \
    -v "$(cd "$(dirname "$BIN")" && pwd):/rom:ro" \
    --entrypoint /bin/bash sftm-quartus -c "
export PATH=/opt/intelFPGA_lite/21.1/quartus/bin:\$PATH
killall jtagd 2>/dev/null || true
jtagd --foreground --config /dev/null >/dev/null 2>&1 &
sleep 4
python3 - /rom/$(basename "$BIN") ${WORDS} > /tmp/rom.tcl <<'PYEOF'
import sys, struct
path, nwords = sys.argv[1], int(sys.argv[2])
data = open(path,'rb').read()
if nwords: data = data[:nwords*4]
if len(data) % 4: data += b'\x00' * (4 - len(data)%4)
w = struct.unpack('>%dI' % (len(data)//4), data)   # 68020 is big-endian
print('package require ::quartus::stp')
print('set hw \"\"')
print('foreach h [get_hardware_names] { if { [string match \"DE-SoC*\" \$h] } { set hw \$h } }')
print('set dev \"\"')
print('foreach d [get_device_names -hardware_name \$hw] { if { [string match \"*5CSEBA6*\" \$d] } { set dev \$d } }')
print('catch { end_insystem_source_probe }')
print('start_insystem_source_probe -hardware_name \$hw -device_name \$dev')
print('set t0 [clock milliseconds]')
tog = 0
for i, v in enumerate(w):
    tog ^= 1
    # src[51]=loader active, [50]=toggle, [49:32]=word addr, [31:0]=data
    val = (1 << 51) | (tog << 50) | ((i & 0x3FFFF) << 32) | v
    print('write_source_data -instance_index 3 -value 0x%016X -value_in_hex' % val)
print('puts \"LOADED %d words in [expr {[clock milliseconds]-\$t0}] ms\"' % len(w))
# drop loader_active so the CPU owns the lane again, then release reset
print('write_source_data -instance_index 3 -value 0')
print('write_source_data -instance_index 2 -value 1')
print('after 500')
print('for { set i 0 } { \$i < 20 } { incr i } { puts \"P3 [read_probe_data -instance_index 2]\"; after 60 }')
print('end_insystem_source_probe')
PYEOF
echo \"tcl lines: \$(wc -l < /tmp/rom.tcl)\"
quartus_stp -t /tmp/rom.tcl 2>&1 | grep -E '^LOADED|^P3 |ERROR'
"
