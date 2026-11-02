#!/bin/bash
# The slim Debian image: a base system with apt ready to install more, init
# and D-Bus, for a runtime (gex's) to start programs in; no desktop. Our
# musl-linux-wasm32 packages first, Debian's arm64 ones (translated) for
# what ours do not have, as the KDE image (kde/build-wasm32.sh), with
# apt's multiarch the same way: wasm32 the native architecture, arm64 the
# foreign one, apt's notes as hooks.
#
#   slim/build-wasm32.sh OUT_DIR POOL...
#
# POOL, DEB_CACHE, GEXCC_PREFIX, REPO_URL and OURS_FOR as
# kde/build-wasm32.sh. Output: OUT_DIR/tree and OUT_DIR/debian-slim.tar.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# One time for all the build stamps (SOURCE_DATE_EPOCH: the same inputs
# give the same bytes), by default this checkout's last commit's
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)}
export SOURCE_DATE_EPOCH
O=${1:?OUT_DIR}
shift
[ $# -gt 0 ] || { echo "usage: $0 OUT_DIR POOL..." >&2; exit 2; }
CACHE=${DEB_CACHE:-${OUT_DIR:-$ROOT/out}/deb}
mkdir -p "$O" "$CACHE"
# The pools' packages, each with the library Depends its cross build could
# not compute (debian/shlibdeps.py: links to the originals where nothing is
# added)
rm -rf "$O/pool"
python3 -I "$ROOT/debian/shlibdeps.py" "$O/pool" "$@"
roots=$(grep -v '^#' "$HERE/roots.txt" | grep . | paste -sd,)
leave=$(grep -v '^#' "$HERE/leave-out.txt" | cut -d'|' -f1 | awk 'NF {print $1}' | paste -sd,)
python3 -I "$ROOT/debian/mkrootfs.py" --pool "$O/pool" --cache "$CACHE" --out "$O/tree" --extra "$roots" --ours-closure --native-ours --apt-notes "$ROOT/kde/apt-notes.txt" --leave-out "$leave" ${OURS_FOR:+--ours-for "$OURS_FOR"} ${REPO_URL:+--repo-url "$REPO_URL" --repo-out "$O/repo"}
if [ -n "${GEXCC_PREFIX:-}" ]; then
    mkdir -p "$O/tree/usr/lib/wasm32-linux-musl"
    cp "$GEXCC_PREFIX/sysroot/lib/libc.so" "$O/tree/usr/lib/wasm32-linux-musl/libc.so"
fi
ex=; [ -L "$O/tree/bin" ] && ex=--exclude=./bin
tar -C "$HERE/overlay" $ex -cf - . | tar -C "$O/tree" --keep-directory-symlink -xf -
# fail-safe maintainer scripts, apt-heal, no py3compile (debian/apt-hooks.sh)
sh "$ROOT/debian/apt-hooks.sh" "$O/tree"
# apt installs anything, whatever it costs ours (slim/apt-anyway.sh)
sh "$HERE/apt-anyway.sh" "$O/tree"
# No repository URL of ours in the image: the host writes
# /etc/apt/sources.list.d/gex.list (the overlay's is a commented example)
rm -f "$O/tree/etc/apt/sources.list.d/gex.sources"
# A user beside root: uid 1000, its home from /etc/skel (owned by it in
# the tar)
if ! grep -q '^user:' "$O/tree/etc/passwd"; then
    echo 'user:x:1000:1000:user:/home/user:/bin/bash' >> "$O/tree/etc/passwd"
    echo 'user:x:1000:' >> "$O/tree/etc/group"
    echo 'user:*:20000:0:99999:7:::' >> "$O/tree/etc/shadow"
    [ -f "$O/tree/etc/gshadow" ] && echo 'user:!::' >> "$O/tree/etc/gshadow"
fi
mkdir -p "$O/tree/home/user"
cp -a "$O/tree/etc/skel/." "$O/tree/home/user/"
for rc in "$O/tree/root/.bashrc" "$O/tree/etc/skel/.bashrc" "$O/tree/home/user/.bashrc"; do
    if [ -f "$rc" ] && ! grep -q gex-welcome "$rc"; then
        printf '\n[ -r /etc/gex-welcome.sh ] && . /etc/gex-welcome.sh\n' >> "$rc"
    fi
done
# The system bus's configuration as Debian's, run as root: dbus-daemon
# drops to messagebus through libcap-ng, whose capset gex does not have
# (the bus exits "Failed to drop capabilities"). /etc/gex/boot starts it.
sed -e '/<user>messagebus<\/user>/d' \
    -e 's|<includedir>system.d</includedir>|<includedir>/usr/share/dbus-1/system.d</includedir>|' \
    -e 's|>contexts/dbus_contexts<|>/usr/share/dbus-1/contexts/dbus_contexts<|' \
    "$O/tree/usr/share/dbus-1/system.conf" > "$O/tree/etc/gex/dbus-system.conf"
# glibc's C.UTF-8 locale, from the libc-bin the image leaves out (an arm64
# program apt installs may refuse a UTF-8 locale without it)
lb=$(ls "$CACHE"/pool/libc-bin_*_arm64.deb 2>/dev/null | tail -1)
if [ -n "$lb" ] && [ ! -d "$O/tree/usr/lib/locale/C.utf8" ]; then
    mkdir -p "$O/tree/usr/lib/locale"
    dpkg-deb --fsys-tarfile "$lb" | tar -C "$O/tree" -xf - ./usr/lib/locale/C.utf8
fi
[ -d "$O/tree/usr/share/glib-2.0/schemas" ] && glib-compile-schemas "$O/tree/usr/share/glib-2.0/schemas"
# Function names out of every wasm module (debian/stripnames.py): only
# backtraces read them, and they are a tenth of the modules' bytes
python3 -I "$ROOT/debian/stripnames.py" "$O/tree"
leak=$(LC_ALL=C grep -rlaF -- "$HOME/" "$O/tree" 2>/dev/null | sed "s|^$O/tree||")
if [ -n "$leak" ]; then
    echo "slim/build-wasm32.sh: $(printf '%s\n' "$leak" | wc -l) files name $HOME, as:" >&2
    printf '%s\n' "$leak" | head -20 >&2
    [ "${GEX_LEAK_CHECK:-fail}" = warn ] || exit 1
fi
tar -C "$O/tree" --owner=0 --group=0 --numeric-owner --sort=name --mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime --exclude=./home/user -cf "$O/debian-slim.tar" .
tar -C "$O/tree" --owner=1000 --group=1000 --numeric-owner --sort=name --mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime -rf "$O/debian-slim.tar" ./home/user
echo "$O/debian-slim.tar: $(du -h "$O/debian-slim.tar" | cut -f1)"
# (downloaded once and kept: the slower level pays)
zstd -q -f -T0 -19 --long=27 "$O/debian-slim.tar" -o "$O/debian-slim.tar.zst"
echo "$O/debian-slim.tar.zst: $(stat -c %s "$O/debian-slim.tar.zst") bytes"
