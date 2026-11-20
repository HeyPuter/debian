#!/bin/bash
# A KDE site from another one's tree, on another runtime and page: BASE's
# session files (kde.tar.zst, the rest bundle and its list, apt/, site.json,
# pack.json's tree entries), hard-linked, with RUNTIME_PACKAGE_DIR (gex's
# page/runtime/build.sh) at rt/ and kde/page/. For a new gex or page without
# building the tree again (mksite.sh does that).
#
#   kde/resite.sh RUNTIME_PACKAGE_DIR BASE OUT
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
RT=$(realpath "${1:?RUNTIME_PACKAGE_DIR}"); BASE=$(realpath "${2:?BASE}"); OUT=$(realpath -m "${3:?OUT}")
[ -f "$RT/index.mjs" ] || { echo "resite: $RT is not a runtime package (gex's page/runtime/build.sh)" >&2; exit 1; }
[ -f "$BASE/site.json" ] && [ -f "$BASE/kde.tar.zst" ] || { echo "resite: $BASE is not a KDE site (site.json, kde.tar.zst)" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
for f in kde.tar.zst lazy.json lazy.json.zst rest.bin rest.bin.json site.json; do
    [ -e "$BASE/$f" ] && ln "$BASE/$f" "$OUT/$f"
done
[ -d "$BASE/apt" ] && cp -al "$BASE/apt" "$OUT/apt"
cp -a "$RT" "$OUT/rt"
cp -a "$HERE/page/." "$OUT/"
# pack.json: the tree's entries only (a site from before the package also
# packed the runtime's files, gex/*.wasm, which rt/ now holds)
python3 -I - "$BASE/pack.json" "$OUT/pack.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p['files'] = {k: v for k, v in p.get('files', {}).items() if not k.startswith('/gex/')}
p.pop('preload', None)
json.dump(p, open(sys.argv[2], 'w'), indent=1)
PY
echo "$OUT: $BASE's tree on $(cat "$RT/package.json" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["name"])') with kde/page"
