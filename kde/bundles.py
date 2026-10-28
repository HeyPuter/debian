#!/usr/bin/env python3
"""The site's tree as two bundles (mksite.sh OPENED=FILE).

    bundles.py TREE.tar OPENED OUT [FRAME_MIB] [LEVEL]

OPENED: the files whose bytes a recorded session used up to its usable
desktop, one path a line, in the order it first used them (test-page.mjs
KDE_OPENED).

The first bundle, OUT/kde.tar, is every directory and link of the tree and
those files' contents in that order: the page fetches and unpacks all of it
before the session starts. The second is every other file's contents as one
uncompressed tar (by path) whose stream is cut into independent zstd frames
of FRAME_MIB MiB (default 8), concatenated as OUT/rest.bin, with its index
OUT/rest.bin.json ({frame, size, frames: [[offset, length], ...]}); the page
reads a file of it by fetching the frames over it by Range and decoding them
(web/src/lazy-cache-worker.js, for every Worker; else shims/browser/js/
lazy-fetch.mjs), never the whole. OUT/lazy.json lists each
of those files as [path, size, "rest.bin#OFFSET", mtime, mode] (web/src/app.js
`lazy`), OFFSET its bytes' place in the tar.

TRIM=FILE: what neither bundle has (kde/trim.txt's form: a glob a line
against the path in the tree, `+GLOB` keeping what an earlier line dropped),
unless the session used it.
"""
import fnmatch
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile

src, opened_list, out = sys.argv[1], sys.argv[2], sys.argv[3]
frame = int(float(sys.argv[4]) * 1048576) if len(sys.argv) > 4 else 8 << 20
level = sys.argv[5] if len(sys.argv) > 5 else '19'


def norm(name):
    """A member's name as the guest's absolute path."""
    n = name[2:] if name.startswith('./') else name
    return '/' + n.strip('/')


rank = {}
for i, line in enumerate(open(opened_list)):
    p = line.rstrip('\n')
    if p and p not in rank:
        rank[p] = i

rules = []
if os.environ.get('TRIM'):
    for line in open(os.environ['TRIM']):
        line = line.strip()
        if line and not line.startswith('#'):
            rules.append((not line.startswith('+'), line.lstrip('+')))


def trimmed(m):
    if not m.isreg() and not m.islnk():
        return False
    p = norm(m.name)
    if p in rank:
        return False
    drop = False
    for d, g in rules:
        if fnmatch.fnmatch(p[1:], g):
            drop = d
    return drop


members = []
dropped = 0
with tarfile.open(src) as t:
    for m in t:
        if trimmed(m):
            dropped += m.size
            continue
        members.append(m)
    datas = {}
    # The used files' contents, and which file each hard link names.
    for m in members:
        if m.isreg() and (norm(m.name) in rank or m.size == 0):
            datas[m.name] = t.extractfile(m).read()

    boot = tarfile.open(os.path.join(out, 'kde.tar'), 'w', format=tarfile.GNU_FORMAT)
    # Directories first, then the used files as they were first used, then
    # the links (a hard link after the file it names).
    for m in members:
        if m.isdir():
            boot.addfile(m)
    used = sorted((m for m in members if m.name in datas), key=lambda m: (rank.get(norm(m.name), -1), m.name))
    for m in used:
        boot.addfile(m, io.BytesIO(datas[m.name]))
    lazy_target = {}  # a lazy file's member name -> its entry
    rest = [m for m in members if m.isreg() and m.name not in datas]
    rest.sort(key=lambda m: m.name)
    for m in members:
        if m.issym() or (m.islnk() and m.linkname in datas):
            boot.addfile(m)
    boot.close()

    # The rest: one tar, written a frame at a time.
    work = tempfile.mkdtemp(dir=out, prefix='.rest-')
    entries = []
    buf = bytearray()
    at = 0
    k = 0

    def flush(final=False):
        global buf, k
        while len(buf) >= frame or (final and buf):
            n = min(frame, len(buf))
            with open(os.path.join(work, f'{k:06d}'), 'wb') as f:
                f.write(buf[:n])
            del buf[:n]
            k += 1

    def put(b):
        global at
        buf.extend(b)
        at += len(b)
        if len(buf) >= frame:
            flush()

    for m in rest:
        h = tarfile.TarInfo(m.name)
        h.size = m.size
        put(h.tobuf(format=tarfile.GNU_FORMAT))
        lazy_target[m.name] = at
        entries.append([norm(m.name), m.size, f'rest.bin#{at}', int(m.mtime), m.mode & 0o7777])
        f = t.extractfile(m)
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            put(b)
        if m.size % 512:
            put(bytes(512 - m.size % 512))
    put(bytes(1024))
    size = at
    flush(True)

# A hard link to a lazy file is the same bytes in the rest bundle.
for m in members:
    if m.islnk() and m.linkname in lazy_target:
        tgt = next(x for x in rest if x.name == m.linkname)
        entries.append([norm(m.name), tgt.size, f'rest.bin#{lazy_target[m.linkname]}', int(tgt.mtime), tgt.mode & 0o7777])

subprocess.run(f"ls | xargs -P {os.cpu_count() or 4} -n 4 nice zstd -{level} -q -f --rm", shell=True, cwd=work, check=True)
frames = []
off = 0
with open(os.path.join(out, 'rest.bin'), 'wb') as o:
    for i in range(k):
        p = os.path.join(work, f'{i:06d}.zst')
        z = open(p, 'rb').read()
        frames.append([off, len(z)])
        o.write(z)
        off += len(z)
        os.unlink(p)
os.rmdir(work)
json.dump({'frame': frame, 'size': size, 'frames': frames}, open(os.path.join(out, 'rest.bin.json'), 'w'))
json.dump({'base': './', 'files': entries}, open(os.path.join(out, 'lazy.json'), 'w'))
boot_size = os.path.getsize(os.path.join(out, 'kde.tar'))
print(f'bundles: trimmed {dropped / 1048576:.1f} MiB; first {len(used)} files, tar {boot_size / 1048576:.1f} MiB; '
      f'rest {len(entries)} files, tar {size / 1048576:.1f} MiB in {len(frames)} frames, {off / 1048576:.1f} MiB compressed')
