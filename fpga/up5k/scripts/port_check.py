#!/usr/bin/env python3
"""A2: module fyracore of rtl/fyracore_picorv32.v == src/fyracore.v at the pin, in parameter list
(names, order, defaults) and port list (names, order, directions, widths). Reads yosys write_json."""
import json, sys
def load(p):
    m = json.load(open(p))["modules"]["fyracore"]
    ports = [(n, d["direction"], len(d["bits"])) for n, d in m["ports"].items()]
    params = list(m.get("parameter_default_values", {}).items())
    return ports, params
a, b = load(sys.argv[1]), load(sys.argv[2])
ok = True
for what, x, y in (("ports", a[0], b[0]), ("parameters", a[1], b[1])):
    if x != y:
        ok = False
        print(f"DIFF in {what}:")
        for i in sorted(set(map(str, x)) ^ set(map(str, y))): print("  ", i)
    else:
        print(f"{what}: {len(x)} identical")
sys.exit(0 if ok else 1)
