"""List members (fields/methods/params) whose type contains a substring.
Usage: python sdk_refs.py <typeSubstring> [ownerSubstring]
  -> prints  OwnerType :: memberKey -> matchedType"""
import os, mmap, re, sys

DUMP = os.environ.get("LMRI_SDK_DUMP", "il2cpp_dump.json")  # REFramework "Dump SDK" output
owner_f = sys.argv[2] if len(sys.argv) > 2 else ""
with open(DUMP, "rb") as f:
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    pat = re.compile(b'"type": "([^"]*' + re.escape(sys.argv[1].encode()) + b'[^"]*)"')
    seen = set()
    for m in pat.finditer(mm):
        j = mm.rfind(b'\n    "', 0, m.start())
        owner = mm[j + 6:mm.find(b'"', j + 6)].decode()
        if owner_f not in owner:
            continue
        a = mm.rfind(b'\n            "', 0, m.start())
        key = mm[a + 14:mm.find(b'"', a + 14)].decode()
        if (owner, key) not in seen:
            seen.add((owner, key))
            print(owner, "::", key, "->", m.group(1).decode())
