import sys
p="/j/src/jtframe/mem/mem.go"
s=open(p).read()
if "sftm: verilog hex" in s:
    print("already patched"); sys.exit(0)
anchor="\t\t\toffset_bytes := offset_words << 1\n"
assert anchor in s, "anchor not found"
ins=('\t\t\tif len(line.At.Offset) > 2 && (line.At.Offset[:2] == "0x" || '
     'line.At.Offset[:2] == "0X") { line.At.Offset = "\'h" + line.At.Offset[2:] }'
     ' // sftm: verilog hex\n')
s=s.replace(anchor, anchor+ins, 1)
open(p,'w').write(s)
print("patched mem.go")
