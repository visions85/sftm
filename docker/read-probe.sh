#!/usr/bin/env bash
# Read the SFTM In-System Probe over the USB Blaster. Run on gamingpc.
#
# The blaster is confirmed connected to the .98 MiSTer: reprogramming the FPGA
# over JTAG resets the core (verified -- attract mode restarted from its title
# screen, and one 1/s screenshot was dropped during configuration).
#
#   probe[ 7: 0]  st_main, the byte the debug overlay claims to display
#   probe[15: 8]  0xA5 signature
#   probe[23:16]  0x5C signature
#   probe[31:24]  0x3C signature
#
# Signatures reading back correctly => the fabric is running this source.
set -euo pipefail
REPO="${REPO:-/home/david/code/sftm-claude}"
N="${1:-12}"      # number of samples

docker run --rm --platform linux/amd64 --privileged \
    -v /dev/bus/usb:/dev/bus/usb -v "${REPO}:/workspace" \
    --entrypoint /bin/bash sftm-quartus -c "
export PATH=/opt/intelFPGA_lite/21.1/quartus/bin:\$PATH
killall jtagd 2>/dev/null || true
jtagd --foreground --config /dev/null >/dev/null 2>&1 &
sleep 3
cat > /tmp/probe.tcl <<'TCL'
package require ::quartus::stp
set hw \"\"
foreach h [get_hardware_names] { if { [string match \"DE-SoC*\" \$h] } { set hw \$h } }
if { \$hw eq \"\" } { puts \"ERROR: no DE-SoC cable\"; exit 1 }
puts \"cable: \$hw\"
set dev \"\"
foreach d [get_device_names -hardware_name \$hw] { if { [string match \"*5CSEBA6*\" \$d] } { set dev \$d } }
if { \$dev eq \"\" } { puts \"ERROR: no Cyclone V in chain\"; exit 1 }
puts \"device: \$dev\"
if { [catch { start_insystem_source_probe -hardware_name \$hw -device_name \$dev } e] } {
    puts \"ERROR starting ISSP: \$e\"; exit 1
}
for { set i 0 } { \$i < ${N} } { incr i } {
    set raw [read_probe_data -instance_index 0]
    # raw is a binary string, MSB first
    set v 0
    foreach c [split \$raw {}] { set v [expr {(\$v<<1) | (\$c eq \"1\")}] }
    set sig3 [expr {(\$v>>24)&0xFF}]
    set sig2 [expr {(\$v>>16)&0xFF}]
    set sig1 [expr {(\$v>> 8)&0xFF}]
    set st   [expr { \$v     &0xFF}]
    puts [format \"sig=%02X/%02X/%02X (want 3C/5C/A5)   st_main=%02X\" \$sig3 \$sig2 \$sig1 \$st]
    after 300
}
end_insystem_source_probe
TCL
quartus_stp -t /tmp/probe.tcl 2>&1 | grep -vE 'Info \(|^\s*$|qenv.sh'
"
