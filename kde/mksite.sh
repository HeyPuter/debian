#!/bin/bash
# The KDE demo's web site: gex's app library (an eject page build, from
# gex's web/build-eject-page.sh) with kde/page/index.html, the session's tree
# as one tar, and pack.json, which names every file served compressed
# (FILE.zst) with its sizes.
#
#   kde/mksite.sh EJECT_PAGE_DIR TREE.tar OUT        (ZSTD_LEVEL: default 12)
#
# UNITS=EJECT_PROJECT: serve that project's function-tier units (its
# build/cgen, as OUT/units) and switch them on: each listed object
# (build.json's "elf-unit" images) placed at its pinned base runs its unit.
# TREE.tar must then hold the same objects the units were built from (the
# project's build/rootfs).
#
# Serve OUT over https (mk/serve.mjs): the page needs cross-origin isolation.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PAGE=$(realpath "${1:?EJECT_PAGE_DIR}"); TAR=$(realpath "${2:?TREE.tar}"); OUT=$(realpath -m "${3:?OUT}")
LEVEL=${ZSTD_LEVEL:-12}
mkdir -p "$OUT"
cp -a "$PAGE/." "$OUT/"
cp "$HERE/page/index.html" "$OUT/index.html"
if [ -n "${UNITS:-}" ]; then
    rm -rf "$OUT/units"
    cp -alL "$UNITS/build/cgen" "$OUT/units"
    python3 -I - "$UNITS/build/build.json" "$OUT/site.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
units = [i for i in m['images'] if i['kind'] == 'elf-unit']
names = sorted({i['path'].rsplit('/', 1)[1] for i in units})
pins = [f"{p['path']}@{p['base']}" for p in m['pins']]
switches = {'cgen': '1', 'cgenurl': 'units', 'elfunits': ','.join(names), 'pins': ','.join(pins)}
json.dump({'tar': ['kde.tar'], 'env': [], 'switches': switches}, open(sys.argv[2], 'w'), indent=1)
print(f'units: {len(units)} objects, {len(pins)} pins')
PY
else
    printf '{"tar": ["kde.tar"], "env": [], "switches": {}}\n' > "$OUT/site.json"
fi
# the tree, and the runtime's large files, compressed
zstd -q -f -T0 "-$LEVEL" --long=27 "$TAR" -o "$OUT/kde.tar.zst"
packed=(kde.tar)
for f in "$OUT"/gex/*.wasm; do
    rel=${f#"$OUT"/}
    zstd -q -f -T0 "-$LEVEL" "$f" -o "$f.zst"
    packed+=("$rel")
done
python3 -I - "$OUT" "$TAR" "${packed[@]}" <<'PY'
import json, os, sys, time
out, tar, names = sys.argv[1], sys.argv[2], sys.argv[3:]
files = {}
for n in names:
    plain = tar if n == 'kde.tar' else os.path.join(out, n)
    files['/' + n] = {'size': os.path.getsize(plain), 'zsize': os.path.getsize(os.path.join(out, n + '.zst'))}
json.dump({'build': time.strftime('%Y%m%d%H%M%S'), 'files': files}, open(os.path.join(out, 'pack.json'), 'w'), indent=1)
total = sum(e['zsize'] for e in files.values())
print(f'{out}: {len(files)} packed files, {total} bytes compressed')
PY
