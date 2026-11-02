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
# One time for all the build stamps (SOURCE_DATE_EPOCH: the same inputs
# give the same bytes), by default this checkout's last commit's
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)}
export SOURCE_DATE_EPOCH
O=${1:-${OUT_DIR:-$ROOT/out}/kde/arm64}
CACHE=${DEB_CACHE:-${OUT_DIR:-$ROOT/out}/deb}
mkdir -p "$O" "$CACHE" "$O/nopool"
roots=$(grep -v '^#' "$HERE/roots.txt" | grep . | paste -sd,)
python3 -I "$ROOT/debian/mkrootfs.py" --pool "$O/nopool" --cache "$CACHE" --out "$O/tree" --extra "$roots"
# (through the tree's /bin -> usr/bin when it is merged, where the
# overlay's /bin/bash link would replace bash with a link to itself)
ex=; [ -L "$O/tree/bin" ] && ex=--exclude=./bin
tar -C "$HERE/overlay" $ex -cf - . | tar -C "$O/tree" --keep-directory-symlink -xf -
# The interactive shells' welcome (the overlay's /etc/gex-welcome.sh), for
# root and for users made from /etc/skel
for rc in "$O/tree/root/.bashrc" "$O/tree/etc/skel/.bashrc"; do
    if [ -f "$rc" ] && ! grep -q gex-welcome "$rc"; then
        printf '\n[ -r /etc/gex-welcome.sh ] && . /etc/gex-welcome.sh\n' >> "$rc"
    fi
done
# The caches packages' triggers make (mkrootfs runs no maintainer scripts),
# made by the build machine's tools: the MIME database (KService and every
# file dialog read it) and the compiled GSettings schemas. Both are
# architecture-independent.
XDG_DATA_DIRS="$O/tree/usr/share" update-mime-database "$O/tree/usr/share/mime"
[ -d "$O/tree/usr/share/glib-2.0/schemas" ] && glib-compile-schemas "$O/tree/usr/share/glib-2.0/schemas"
"$HERE/sycoca.sh" "$O/tree"
tar -C "$O/tree" --owner=0 --group=0 --numeric-owner --sort=name --mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime -cf "$O/kde.tar" .
echo "$O/kde.tar: $(du -h "$O/kde.tar" | cut -f1)"
