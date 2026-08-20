#!/usr/bin/env bash
# Release the game from reset over JTAG and read the ROM-survival probe.
#
#   ./docker/run-probe3.sh [force_run 0|1] [samples]
#
# Requires the FPGA to have been configured from the .sof over JTAG (the SLD hub
# is not reachable with an HPS-loaded rbf -- see doc/PORTING.md).
#
# probe2 (id SFRN, 64 bit):
#   [63:56] 0x7E sig  [48] force_run echo  [47] m_got
#   [46:32] completed main fetches  [31:0] FIRST longword fetched
#
# The first longword must read 0x00008000 for SDRAM to have kept the ROM.
set -euo pipefail
FR="${1:-1}"; N="${2:-40}"
docker run --rm --platform linux/amd64 --privileged \
    -v /dev/bus/usb:/dev/bus/usb -v /home/david/code/sftm-claude:/workspace \
    --entrypoint /bin/bash sftm-quartus -c "
export PATH=/opt/intelFPGA_lite/21.1/quartus/bin:\$PATH
killall jtagd 2>/dev/null || true
jtagd --foreground --config /dev/null >/dev/null 2>&1 &
sleep 4
cat > /tmp/p3.tcl <<TCL
package require ::quartus::stp
set hw \"\"
foreach h [get_hardware_names] { if { [string match \"DE-SoC*\" \\\$h] } { set hw \\\$h } }
set dev \"\"
foreach d [get_device_names -hardware_name \\\$hw] { if { [string match \"*5CSEBA6*\" \\\$d] } { set dev \\\$d } }
start_insystem_source_probe -hardware_name \\\$hw -device_name \\\$dev
puts \"instances: [get_insystem_source_probe_instance_info -hardware_name \\\$hw -device_name \\\$dev]\"
write_source_data -instance_index 2 -value ${FR} -value_in_hex
after 200
for { set i 0 } { \\\$i < ${N} } { incr i } { puts \"P3 [read_probe_data -instance_index 2]\"; after 50 }
end_insystem_source_probe
TCL
quartus_stp -t /tmp/p3.tcl 2>&1 | grep -E '^P3 |^instances:|ERROR|Error'
"
