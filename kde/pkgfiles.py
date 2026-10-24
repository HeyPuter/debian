#!/usr/bin/env python3
"""The files of packages that TREE lacks, and the shared libraries their
programs and plugins need (DT_NEEDED, transitively) that TREE lacks too:
one path per line, relative to FULL (a Debian tree with its dpkg
database), for tar -T.

    kde/pkgfiles.py FULL TREE PACKAGE...

TREE is an ejected tree (what a recorded session read): a program the
session never ran is not in it. Documentation, manual pages and
translations are left out."""
import os
import re
import subprocess
import sys

full, tree, want = sys.argv[1], sys.argv[2], sys.argv[3:]
skip = ('usr/share/doc/', 'usr/share/man/', 'usr/share/locale/', 'usr/share/help/', 'usr/share/info/')
libdirs = ['usr/lib/aarch64-linux-gnu', 'usr/lib']


def present(rel):
    # merged /usr: an ejected tree has a file at the path the session
    # opened it by (often /lib/...), and a library at its soname
    # (libX.so.6), the name the loader opened, not the file's
    names = [rel]
    while re.search(r'\.so(\.\d+)+$', names[-1]):
        names.append(names[-1].rsplit('.', 1)[0])
    names = [n for n in names if not n.endswith('.so')] or [rel]
    for n in names:
        alias = n[4:] if n.startswith(('usr/lib/', 'usr/bin/', 'usr/sbin/')) else None
        if os.path.lexists(os.path.join(tree, n)) or (alias and os.path.lexists(os.path.join(tree, alias))):
            return True
    return False


def needed(rel):
    try:
        out = subprocess.run(['readelf', '-d', os.path.join(full, rel)], capture_output=True, text=True).stdout
    except OSError:
        return []
    libs = re.findall(r'\(NEEDED\)\s+Shared library: \[([^\]]+)\]', out)
    # where it says its libraries are, first (libpulse's private
    # libpulsecommon is in .../pulseaudio, its RUNPATH)
    here = os.path.dirname(rel)
    dirs = [d.replace('$ORIGIN', '/' + here).replace('${ORIGIN}', '/' + here).strip('/')
            for m in re.findall(r'\((?:RUNPATH|RPATH)\)\s+Library (?:runpath|rpath): \[([^\]]+)\]', out) for d in m.split(':') if d]
    return [(lib, dirs) for lib in libs]


out, elves = [], []
info = os.path.join(full, 'var/lib/dpkg/info')
for p in want:
    for name in (f'{p}.list', f'{p}:arm64.list'):
        lst = os.path.join(info, name)
        if not os.path.exists(lst):
            continue
        for line in open(lst):
            rel = line.strip().lstrip('/')
            src = os.path.join(full, rel)
            if not rel or rel.startswith(skip) or (os.path.isdir(src) and not os.path.islink(src)) or not os.path.lexists(src):
                continue
            if not present(rel):
                out.append(rel)
            # its libraries, whether TREE has it or not (a tree given these
            # files before may lack what they need)
            if os.path.isfile(src) and open(src, 'rb').read(4) == b'\x7fELF':
                elves.append(rel)
seen = set()
while elves:
    for lib, dirs in needed(elves.pop()):
        if lib in seen:
            continue
        seen.add(lib)
        for d in [os.path.normpath(x) for x in dirs] + libdirs:
            rel = f'{d}/{lib}'
            if not os.path.lexists(os.path.join(full, rel)):
                continue
            real = os.path.relpath(os.path.realpath(os.path.join(full, rel)), full)
            if not present(rel):
                out += [rel] + ([real] if real != rel else [])
            # a library TREE has may need one it lacks: a file the session
            # only read (libpulse.so.0, never loaded), without libpulsecommon
            elves.append(real)
            break
print('\n'.join(dict.fromkeys(out)))
