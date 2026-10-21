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
roots=$(grep -v '^#' "$HERE/chroot-roots.txt" | tr -s ' \t\n' ',' | sed 's/^,//; s/,$//')
python3 -I "$HERE/../mkrootfs.py" --arch amd64 --pool "$D.nopool" --cache "$CACHE" --out "$D" --extra "$roots"
# All of glibc's iconv modules: the image keeps only the Unicode and a few
# Western ones, and a build's msgfmt converts every .po file's charset
# (e2fsprogs' fr.po is ISO-8859-1)
libc6=$(ls "$CACHE"/pool/libc6_*_amd64.deb | tail -1)
dpkg-deb --fsys-tarfile "$libc6" | tar -x -C "$D" --wildcards './usr/lib/x86_64-linux-gnu/gconv/*'
sed -i '\|^path-exclude=/usr/lib/\*/gconv/\*.so$|d' "$D/etc/dpkg/dpkg.cfg.d/"*
# What gcc's and the other maintainer scripts would have linked (alternatives
# mkrootfs.py does not know): cc, c++, cpp.
for l in cc:gcc c++:g++ cpp:cpp-14; do
    n=${l%%:*} t=${l#*:}
    [ -e "$D/usr/bin/$n" ] || ln -s "$t" "$D/usr/bin/$n"
done
# The XML catalog docbook-xml's and docbook-xsl's maintainer scripts would
# have registered (update-xmlcatalog): without it xmlto and xsltproc fetch
# the DTDs from the network, and fail
mkdir -p "$D/etc/xml"
{
    echo '<?xml version="1.0"?>'
    echo '<catalog xmlns="urn:oasis:names:tc:entity:xmlns:xml:catalog">'
    (cd "$D" && find usr/share/xml -name catalog.xml | sort) | sed 's|.*|  <nextCatalog catalog="/&"/>|'
    echo '</catalog>'
} > "$D/etc/xml/catalog"
echo "$D"
