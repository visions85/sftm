# tb_romfetch -- free-running ROM fetch verification

Unlike every other testbench in this project, this one does **not** force
`clkena` or hand-craft bus cycles. It releases TG68K from reset and lets it run
freely out of a model of the *real* 1 MB program ROM, checking every single
instruction fetch byte-for-byte against the ROM image.

## Building the ROM image

The ROM is copyrighted and is **not** in this repository. Rebuild it from your
own `sftm` romset with `doc/rom_interleave.py`, then flatten it to hex:

```sh
python3 doc/rom_interleave.py            # -> prog.bin (1 MB)
python3 - <<'PY'
import struct
d = open('prog.bin','rb').read()
with open('/tmp/prog32.hex','w') as f:
    for i in range(0, len(d), 4):
        f.write("%08x\n" % struct.unpack_from(">I", d, i)[0])
PY
```

## Running

```sh
iverilog -g2012 -o /tmp/tb_rf.vvp cores/sftm/ver/romfetch/tb_romfetch.v \
    cores/sftm/hdl/sftm_main.v cores/sftm/hdl/sftm_ram.v \
    cores/sftm/hdl/sftm_prot.v cores/sftm/hdl/tg68k/TG68KdotC_Kernel_conv.v
vvp /tmp/tb_rf.vvp
```

Parameters (override with `-Ptb_romfetch.NAME=value`):

| Name     | Default | Meaning |
|----------|---------|---------|
| `MODE`   | 0       | 0 = ideal always-ready memory. 1 = bcache-like model: a fetch starts only on a LOW->HIGH edge of `rom_cs`, takes `LATENCY` cycles, and deliberately does **not** refetch when `rom_addr` changes while `rom_cs` stays high. Mode 1 is the exact hazard `cpu_rom_gap` exists to prevent. |
| `LATENCY`| 4       | Mode 1 fetch latency in clocks. |
| `RUNLEN` | 20000   | Clocks to run after boot. TG68K simulation is slow; expect tens of seconds. |
| `DEBUG`  | 0       | Per-cycle boot handshake trace. |

## Result as of this commit

Both modes: **0 wrong words out of 3694 (mode 0) / 1628 (mode 1) fetches.**
The ROM address path, the `rom_half` selection, and the `cpu_rom_gap`
handshake are all byte-exact.

## Gotchas

* Do not read the 256K-entry ROM array from an `always @(*)` block -- iverilog
  builds a sensitivity list over every element and elaboration hangs for
  10+ minutes. Register the read instead.
* The mode-1 edge detector must use case-equality (`rom_cs === 1'b1 &&
  cs_q !== 1'b1`). With plain `!cs_q` the first-cycle X propagates and the
  model deadlocks with `rom_ok` stuck low.
