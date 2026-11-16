"""List top-level type names in il2cpp_dump.json matching a regex.
Usage: python sdk_types.py <regex>"""
import os, mmap, re, sys

DUMP = os.environ.get("LMRI_SDK_DUMP", "il2cpp_dump.json")  # REFramework "Dump SDK" output
pat = re.compile(rb'\n    "([^"]+)": \{')
want = re.compile(sys.argv[1].encode())
with open(DUMP, "rb") as f:
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    for m in pat.finditer(mm):
        if want.search(m.group(1)):
            print(m.group(1).decode())
