#!/usr/bin/env python3
"""The browser's KDE tree as one tar: the arm64 tree less kde/trim.txt.

    kde/pack.py TREE OUT.tar

Owners are root, times kept, hard links kept; the archive lists
directories before their contents (the page's untar needs no order, but
`tar t` reads better).
"""
import fnmatch, os, sys, tarfile

here = os.path.dirname(os.path.abspath(__file__))
tree, out = sys.argv[1], sys.argv[2]
rules = []
for line in open(os.path.join(here, 'trim.txt')):
    line = line.strip()
    if line and not line.startswith('#'):
        rules.append((line[0] != '+', line.lstrip('+')))


def dropped(rel):
    d = False
    for drop, g in rules:
        if fnmatch.fnmatchcase(rel, g):
            d = drop
    return d


n = size = skipped = 0
with tarfile.open(out, 'w', format=tarfile.GNU_FORMAT) as t:
    def reset(ti):
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = 'root'
        return ti
    for d, dirs, files in os.walk(tree):
        dirs.sort()
        rel_d = os.path.relpath(d, tree)
        for name in sorted(dirs) + sorted(files):
            p = os.path.join(d, name)
            rel = os.path.normpath(os.path.join(rel_d, name))
            if dropped(rel):
                skipped += 1
                continue
            if name in dirs and not os.path.islink(p):
                t.add(p, arcname=rel, recursive=False, filter=reset)
                continue
            t.add(p, arcname=rel, recursive=False, filter=reset)
            n += 1
            if os.path.isfile(p) and not os.path.islink(p):
                size += os.path.getsize(p)
print(f'{out}: {n} files, {size / 1048576:.0f} MiB, {skipped} left out', file=sys.stderr)
