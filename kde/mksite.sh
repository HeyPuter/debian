#!/bin/bash
# The KDE demo's web site: gex's app library (an eject page build, from
# gex's web/build-eject-page.sh) with kde/page/ (index.html), the session's tree
# as one tar, and pack.json, which names every file served compressed
# (FILE.zst) with its sizes.
#
#   kde/mksite.sh EJECT_PAGE_DIR TREE.tar|TREE OUT   (ZSTD_LEVEL: default 12)
#
# A TREE directory (an eject project's build/rootfs) is given the paths
# kde/site-files.txt names from FULL (the tree the session was recorded
# on: build-arm64.sh's or build-wasm32.sh's tree), when FULL is set, and
# the session's overlay; then gets its KService database built in it
# (kde/sycoca.sh: it has to be the final tree's, or every session rebuilds
# it) and is tarred here.
#
# ADD=DIR: laid over the tree after FULL's files.
#
# UNITS=EJECT_PROJECT: serve that project's function-tier units (its
# build/cgen, as OUT/units) and switch them on: each listed object
# (build.json's "elf-unit" images) placed at its pinned base runs its unit.
# TREE.tar must then hold the same objects the units were built from (the
# project's build/rootfs).
#
# APT_REPO=DIR: an apt repository (build-wasm32.sh's REPO_URL repo) served
# under OUT/apt/, which the page answers the guest's http://gex-site/ from
# (site.json pageHosts): fetched only when apt asks for a file.
#
# OPENED=FILE: two bundles (kde/bundles.py), not one: OUT/kde.tar only what
# a recorded session used up to its desktop (FILE, test-page.mjs
# KDE_OPENED), in the order it did, with kde/boot-files.txt's paths, and
# every other file in the rest bundle
# (OUT/rest.bin, read by Range as the guest reads); kde/trim.txt's paths in
# neither, unless the session used them.
#
# Serve OUT over https (mk/serve.mjs): the page needs cross-origin isolation.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PAGE=$(realpath "${1:?EJECT_PAGE_DIR}"); TAR=$(realpath "${2:?TREE.tar}"); OUT=$(realpath -m "${3:?OUT}")
LEVEL=${ZSTD_LEVEL:-12}
mkdir -p "$OUT"
if [ -d "$TAR" ]; then
    if [ -n "${FULL:-}" ]; then
        # as FULL has them: a symlink there replaces the directory an
        # eject made of it
        { grep -v '^#\|^pkg ' "$HERE/site-files.txt" | grep .
          python3 -I "$HERE/pkgfiles.py" "$FULL" "$TAR" $(sed -n 's/^pkg //p' "$HERE/site-files.txt"); } |
            tar -C "$FULL" -cf - -T - | tar -C "$TAR" --recursive-unlink -xf -
    fi
    # ADD=DIR: a tree laid over it after FULL's files (programs of another
    # architecture in place of the tree's, with their libraries)
    [ -n "${ADD:-}" ] && tar -C "$ADD" -cf - . | tar -C "$TAR" --keep-directory-symlink -xf -
    cp -a "$HERE/overlay/." "$TAR/"
    "$HERE/sycoca.sh" "$TAR" > /dev/null
    (cd "$TAR" && tar --owner=0 --group=0 -cf "$OUT/kde.tar" $(ls -A))
    TAR=$OUT/kde.tar
fi
cp -a "$PAGE/." "$OUT/"
# the landing page and its files (kde/page/)
cp -a "$HERE/page/." "$OUT/"
if [ -n "${UNITS:-}" ]; then
    rm -rf "$OUT/units"
    cp -alL "$UNITS/build/cgen" "$OUT/units"
    python3 -I - "$UNITS/build/build.json" "$OUT/site.json" "$UNITS/build/rootfs" <<'PY'
import json, os, sys
m = json.load(open(sys.argv[1]))
units = [i for i in m['images'] if i['kind'] == 'elf-unit']
names = sorted({i['path'].rsplit('/', 1)[1] for i in units})
root = sys.argv[3]
def span(path):
    # the object's extent from its first PT_LOAD, rounded to 64 KiB with 64 KiB
    # of slack, as the eject's layout gives each its share: told none, the
    # page's placement table puts the next object inside it
    import struct
    with open(os.path.join(root, path.lstrip('/')), 'rb') as f:
        h = f.read(64)
        phoff, phentsize, phnum = struct.unpack_from('<Q', h, 0x20)[0], *struct.unpack_from('<HH', h, 0x36)
        f.seek(phoff)
        ph = f.read(phentsize * phnum)
    loads = [struct.unpack_from('<IIQQQQQ', ph, i * phentsize) for i in range(phnum)]
    loads = [l for l in loads if l[0] == 1]
    lo = min(l[3] for l in loads) & ~0xfff
    hi = max(l[3] + l[6] for l in loads)
    return ((hi - lo + 0xffff) & ~0xffff) + 0x10000
pins = [f"{p['path']}@{p['base']}+{span(p['path']):#x}" for p in m['pins']]
switches = {'cgen': '1', 'cgenurl': 'units', 'elfunits': ','.join(names), 'pins': ','.join(pins)}
# the project's own region above the placement window, when its libraries have one
if int(m.get('pin_region', '0x0'), 16):
    switches['pinregion'] = m['pin_region']
# each unit's key and its object's identity as placed (`base:key:identity:
# path`), which the page takes rather than hashing every object in every
# process that maps it; a build from before the eject recorded them has none
ids = ';'.join(f"{int(i['base'], 16):x}:{i['identity']}:{i['image']}:{i['path']}" for i in units if i.get('image'))
site = {'tar': ['kde.tar'], 'env': [], 'switches': switches}
if ids:
    site['identities'] = ids
json.dump(site, open(sys.argv[2], 'w'), indent=1)
print(f'units: {len(units)} objects, {len(pins)} pins')
PY
else
    printf '{"tar": ["kde.tar"], "env": [], "switches": {}}\n' > "$OUT/site.json"
fi
if [ -n "${APT_REPO:-}" ]; then
    rm -rf "$OUT/apt"
    cp -alL "$APT_REPO" "$OUT/apt" 2>/dev/null || { rm -rf "$OUT/apt"; cp -aL "$APT_REPO" "$OUT/apt"; }
    python3 -I - "$OUT/site.json" <<'PY'
import json, sys
p = sys.argv[1]
site = json.load(open(p))
site['pageHosts'] = {'gex-site': 'apt/'}
json.dump(site, open(p, 'w'), indent=1)
PY
fi
if [ -n "${OPENED:-}" ]; then
    full=$OUT/.full.tar
    if [ "$TAR" = "$OUT/kde.tar" ]; then mv "$TAR" "$full"; else full=$TAR; fi
    rm -f "$OUT/rest.bin" "$OUT/rest.bin.json" "$OUT/lazy.json"
    # The page reads the program it starts (index.html's `exe`) from the
    # first bundle itself, before the kernel counts a read: first.
    exe=$(sed -n "s/^ *exe: '\([^']*\)'.*/\1/p" "$HERE/page/index.html" | head -1)
    # kde/boot-files.txt: what the session may read before its desktop is up
    # that the recorded run did not (a size of the wallpaper), after it.
    { [ -n "$exe" ] && echo "$exe"; cat "$OPENED"; grep -v '^#' "$HERE/boot-files.txt" | grep .; } | awk '!seen[$0]++' > "$OUT/.opened"
    TRIM="$HERE/trim.txt" nice python3 -I "$HERE/bundles.py" "$full" "$OUT/.opened" "$OUT"
    rm "$OUT/.opened"
    [ "$full" = "$OUT/.full.tar" ] && rm "$full"
    TAR=$OUT/kde.tar
    python3 -I - "$OUT/site.json" <<'PY'
import json, sys
p = sys.argv[1]
site = json.load(open(p))
site['lazy'] = 'lazy.json'
json.dump(site, open(p, 'w'), indent=1)
PY
fi
# the tree, and the runtime's large files, compressed
zstd -q -f -T0 "-$LEVEL" --long=27 "$TAR" -o "$OUT/kde.tar.zst"
packed=(kde.tar)
for f in "$OUT"/gex/*.wasm; do
    rel=${f#"$OUT"/}
    zstd -q -f -T0 "-$LEVEL" "$f" -o "$f.zst"
    packed+=("$rel")
done
# the rest bundle's file list, read before the session starts: packed too,
# with its bytes' hash, which is how the page knows to fetch it so
if [ -f "$OUT/lazy.json" ]; then
    zstd -q -f -19 "$OUT/lazy.json" -o "$OUT/lazy.json.zst"
    packed+=(lazy.json)
fi
python3 -I - "$OUT" "$TAR" "${packed[@]}" <<'PY'
import json, os, sys, time
out, tar, names = sys.argv[1], sys.argv[2], sys.argv[3:]
files = {}
for n in names:
    plain = tar if n == 'kde.tar' else os.path.join(out, n)
    files['/' + n] = {'size': os.path.getsize(plain), 'zsize': os.path.getsize(os.path.join(out, n + '.zst'))}
    if n == 'lazy.json':
        import hashlib
        files['/' + n]['h'] = hashlib.sha256(open(plain, 'rb').read()).hexdigest()[:16]
json.dump({'build': time.strftime('%Y%m%d%H%M%S'), 'files': files}, open(os.path.join(out, 'pack.json'), 'w'), indent=1)
total = sum(e['zsize'] for e in files.values())
print(f'{out}: {len(files)} packed files, {total} bytes compressed')
PY
[ "$TAR" = "$OUT/kde.tar" ] && rm "$TAR"
exit 0
