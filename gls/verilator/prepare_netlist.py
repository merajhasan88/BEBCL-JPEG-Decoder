#!/usr/bin/env python3
"""Rewrite a Quartus post-fit netlist (.vo) so that Verilator can simulate it together with
cycloneii_cells.v (independent zero-delay behavioural cell models):
  * $sdf_annotate commented out
  * I/O cells split into cycloneii_io_in / cycloneii_io_out by their operation_mode
  * '[n]' inside escaped instance names replaced by '_n_' (they collide with vectors in Verilator)
  * output-port connections to bit-selects routed through named wires
usage: prepare_netlist.py in.vo out.vo"""
import re, sys
v = open(sys.argv[1]).read()
v = re.sub(r'(initial \$sdf_annotate\([^)]*\);)', r'// \1  // zero-delay run', v)
modes = dict(re.findall(r'defparam (\\\S+) \.operation_mode = "(\w+)";', v))
def io(m):
    inst = m.group(1)
    return ("cycloneii_io_out " if modes.get(inst) in ("output", "bidir") else "cycloneii_io_in ") + inst + " ("
v, n_io = re.subn(r'cycloneii_io (\\\S+) \(', io, v)
def fix(m): return m.group(1) + m.group(2).replace('[', '_').replace(']', '_') + m.group(3)
v, n1 = re.subn(r'^(cycloneii_\w+ |[a-z_0-9]+ )(\\\S*\[\d+\](?:\[\d+\])* )(\()', fix, v, flags=re.M)
v, n2 = re.subn(r'^(defparam )(\\\S*\[\d+\](?:\[\d+\])* )(\.)', fix, v, flags=re.M)
pat = re.compile(r'\.(regout|combout|dataout|portadataout|portbdataout|cout|padio)\((\\\S+ |[A-Za-z_][A-Za-z_0-9]*)\[(\d+)\]\)')
decls, seen = [], set()
def bit(m):
    port, name, idx = m.groups()
    wname = (name.rstrip() + '__bit' + idx + ' ') if name.startswith('\\') else (name + '__bit' + idx)
    if (name, idx) not in seen:
        seen.add((name, idx)); decls.append("wire %s;\nassign %s[%s] = %s;" % (wname, name, idx, wname))
    return ".%s(%s)" % (port, wname)
v, n3 = pat.subn(bit, v)
i = v.index("\ncycloneii_")
v = v[:i] + "\n// --- Verilator workaround: outputs driving bit-selects go through named wires ---\n" + "\n".join(decls) + "\n" + v[i:]
open(sys.argv[2], 'w').write(v)
print("io cells: %d, renamed instances: %d (+%d defparams), bit-select outputs rewired: %d" % (n_io, n1, n2, n3))
