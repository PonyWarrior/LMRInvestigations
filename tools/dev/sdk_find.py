"""Print a type's block from the ~2 GB il2cpp_dump.json without loading it.
Usage: python sdk_find.py <TypeFQN> [filter_substring] [max_chars]"""
import os, mmap, sys, re

DUMP = os.environ.get("LMRI_SDK_DUMP", "il2cpp_dump.json")  # REFramework "Dump SDK" output
name = sys.argv[1]
flt = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] != "-" else None
maxc = int(sys.argv[3]) if len(sys.argv) > 3 else 400000

with open(DUMP, "rb") as f:
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    key = b'\n    "' + name.encode() + b'": {'
    i = mm.find(key)
    if i < 0:
        print("not found:", name); sys.exit(1)
    j = mm.find(b'\n    }', i + len(key))
    blk = mm[i:min(j + 6, i + maxc)].decode("utf-8", "replace")
    if flt:
        for ln in blk.splitlines():
            if flt.lower() in ln.lower():
                print(ln.strip()[:220])
    else:
        print(blk)
