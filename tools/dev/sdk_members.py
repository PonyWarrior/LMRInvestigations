"""List member keys (methods/fields) of a type, with params/returns for methods.
Usage: python sdk_members.py <TypeFQN> [filter_substring]"""
import os, json, mmap, sys

DUMP = os.environ.get("LMRI_SDK_DUMP", "il2cpp_dump.json")  # REFramework "Dump SDK" output
name = sys.argv[1]
flt = (sys.argv[2] if len(sys.argv) > 2 else "").lower()
with open(DUMP, "rb") as f:
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    key = b'\n    "' + name.encode() + b'": {'
    i = mm.find(key)
    if i < 0:
        print("not found:", name); sys.exit(1)
    j = mm.find(b'\n    }', i + len(key))
    blk = json.loads(b"{" + mm[i + 1:j + 6] + b"}")[name]
for sect in ("methods", "fields", "properties"):
    for k, v in (blk.get(sect) or {}).items():
        if flt and flt not in k.lower():
            continue
        if sect == "methods" and isinstance(v, dict):
            ps = ", ".join(f"{p.get('type')} {p.get('name')}" for p in v.get("params") or [])
            print(f"M {k}({ps}) -> {v.get('returns', {}).get('type')}")
        else:
            print(f"{sect[0].upper()} {k} -> {v.get('type') if isinstance(v, dict) else v}")
