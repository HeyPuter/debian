#!/bin/bash
# The cross build's chroot: Debian trixie amd64 with chroot-roots.txt, made
# without root (debian/mkrootfs.py --arch amd64, no maintainer scripts).
#
#   debian/cross/mkchroot.sh DIR      (DEB_CACHE: the .deb cache)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
D=$(realpath -m "${1:?DIR}")
CACHE=${DEB_CACHE:-$(dirname "$D")/deb}
mkdir -p "$CACHE" "$D.nopool"
roots=$(grep -v '^#' "$HERE/chroot-roots.txt" | grep . | paste -sd,)
python3 -I "$HERE/../mkrootfs.py" --arch amd64 --pool "$D.nopool" --cache "$CACHE" --out "$D" --extra "$roots"
# What gcc's and the other maintainer scripts would have linked (alternatives
# mkrootfs.py does not know): cc, c++, cpp.
for l in cc:gcc c++:g++ cpp:cpp-14; do
    n=${l%%:*} t=${l#*:}
    [ -e "$D/usr/bin/$n" ] || ln -s "$t" "$D/usr/bin/$n"
done
echo "$D"
