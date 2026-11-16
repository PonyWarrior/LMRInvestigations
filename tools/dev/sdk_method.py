"""Print method entries (by key prefix) inside a type block of il2cpp_dump.json.
Usage: python sdk_method.py <TypeFQN> <methodKey> [<methodKey>...] (keys like EnemyName758033)"""
import os, mmap, sys

DUMP = os.environ.get("LMRI_SDK_DUMP", "il2cpp_dump.json")  # REFramework "Dump SDK" output
with open(DUMP, "rb") as f:
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    i = mm.find(b'\n    "' + sys.argv[1].encode() + b'": {')
    if i < 0:
        print("type not found"); sys.exit(1)
    for k in sys.argv[2:]:
        j = mm.find(b'"' + k.encode() + b'"', i)
        print(mm[j:j + 800].decode("utf-8", "replace"))
        print("=====")
