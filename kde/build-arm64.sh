#!/bin/bash
# The KDE session's rootfs from Debian's own arm64 packages (translated by
# gex): mkrootfs.py over roots.txt with none of our wasm32 packages, then the
# session's files (overlay/).
#
#   kde/build-arm64.sh [OUT_DIR]     (default: out/kde/arm64; tree/ and kde.tar)
#
# The Debian cache is $DEB_CACHE (default out/deb).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
O=${1:-${OUT_DIR:-$ROOT/out}/kde/arm64}
CACHE=${DEB_CACHE:-${OUT_DIR:-$ROOT/out}/deb}
mkdir -p "$O" "$CACHE" "$O/nopool"
roots=$(grep -v '^#' "$HERE/roots.txt" | grep . | paste -sd,)
python3 -I "$ROOT/debian/mkrootfs.py" --pool "$O/nopool" --cache "$CACHE" --out "$O/tree" --extra "$roots"
cp -a "$HERE/overlay/." "$O/tree/"
tar -C "$O/tree" --owner=0 --group=0 --numeric-owner --sort=name -cf "$O/kde.tar" .
echo "$O/kde.tar: $(du -h "$O/kde.tar" | cut -f1)"
