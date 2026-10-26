#!/bin/bash
# The KDE session's rootfs with our musl-linux-wasm32 packages (built from
# Debian's sources by debian/cross/xbuild.py) in place of Debian's arm64
# ones: mkrootfs.py over roots.txt, the image taking from our pools the
# closure of the roots, Debian's arm64 packages only for what ours do not
# have. Then the session's files (overlay/), as build-arm64.sh.
#
#   kde/build-wasm32.sh [OUT_DIR] POOL...   (default OUT_DIR: out/kde/wasm32)
#
# POOL: directories of our .debs (mkdebs.py's pool, xbuild.py's WORK/debs);
# for a package in more than one, the later pool's copy. The Debian cache is
# $DEB_CACHE (default out/deb).
#
# GEXCC_PREFIX: the gexcc install our packages were built with (its
# libc.so goes into the tree).
#
# OURS_FOR=PKG,...: these of ours replace Debian's of the same name even
# where Debian's is an arm64 program (Konsole as wasm32 in an otherwise
# arm64 Plasma), with the libraries they load
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
O=${1:-${OUT_DIR:-$ROOT/out}/kde/wasm32}
shift || true
[ $# -gt 0 ] || { echo "usage: $0 OUT_DIR POOL..." >&2; exit 2; }
CACHE=${DEB_CACHE:-${OUT_DIR:-$ROOT/out}/deb}
mkdir -p "$O" "$CACHE"
rm -rf "$O/pool"
mkdir "$O/pool"
for p in "$@"; do
    for d in "$p"/*.deb; do
        n=$(basename "$d"); n=${n%%_*}
        rm -f "$O/pool/$n"_*.deb
        ln -s "$(realpath "$d")" "$O/pool/"
    done
done
roots=$(grep -v '^#' "$HERE/roots.txt" | grep . | paste -sd,)
python3 -I "$ROOT/debian/mkrootfs.py" --pool "$O/pool" --cache "$CACHE" --out "$O/tree" --extra "$roots" --ours-closure ${OURS_FOR:+--ours-for "$OURS_FOR"}
# gexcc's libc.so, which its shared programs and libraries (GEXCC_SHARED,
# as xbuild.py builds them) load: no Debian package has it
if [ -n "${GEXCC_PREFIX:-}" ]; then
    mkdir -p "$O/tree/usr/lib/wasm32-linux-musl"
    cp "$GEXCC_PREFIX/sysroot/lib/libc.so" "$O/tree/usr/lib/wasm32-linux-musl/libc.so"
fi
# (through the tree's /bin -> usr/bin when it is merged, where the
# overlay's /bin/bash link would replace bash with a link to itself)
ex=; [ -L "$O/tree/bin" ] && ex=--exclude=./bin
tar -C "$HERE/overlay" $ex -cf - . | tar -C "$O/tree" --keep-directory-symlink -xf -
XDG_DATA_DIRS="$O/tree/usr/share" update-mime-database "$O/tree/usr/share/mime"
[ -d "$O/tree/usr/share/glib-2.0/schemas" ] && glib-compile-schemas "$O/tree/usr/share/glib-2.0/schemas"
"$HERE/sycoca.sh" "$O/tree"
tar -C "$O/tree" --owner=0 --group=0 --numeric-owner --sort=name -cf "$O/kde.tar" .
echo "$O/kde.tar: $(du -h "$O/kde.tar" | cut -f1)"
