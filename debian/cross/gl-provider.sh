#!/bin/bash
# The target's OpenGL, EGL and GBM, as Debian packages a cross build depends
# on: gex's guest GL driver (gex's guest/gl/gexgl.c, which forwards GL and EGL
# to the page's Mesa over /dev/gex-gl) built with gexcc as wasm side modules,
# with the Khronos headers and pkg-config files of Debian's own -dev packages.
# No Mesa or libglvnd is built for the target.
#
#   debian/cross/gl-provider.sh GEX_SRC GEXCC_PREFIX WORK     (DEB_CACHE: .deb cache)
#
# Writes WORK/debs/gex-gl_VERSION_musl-linux-wasm32.deb (the libraries) and
# gex-gl-dev (headers, .pc files, the unversioned .so links). They provide
# the names Build-Depends uses: libgl-dev, libgles-dev, libegl-dev,
# libopengl-dev, libglx-dev, libgbm-dev, libglvnd-dev and the runtime
# libraries' names. GBM has no driver behind it in gex: libgbm.so.1 has every
# gbm.h function, and gbm_create_device answers NULL (so a KMS platform
# plugin builds, and reports no device at run time).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(realpath "${1:?GEX_SRC}"); P=$(realpath "${2:?GEXCC_PREFIX}"); W=$(realpath -m "${3:?WORK}")
CACHE=${DEB_CACHE:-$W/deb}
MA=wasm32-linux-musl
VER=1.0~gex1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$W/debs" "$T/hdr" "$T/lib/DEBIAN" "$T/dev/DEBIAN"
L=$T/lib/usr/lib/$MA D=$T/dev/usr/lib/$MA
mkdir -p "$L" "$D/pkgconfig" "$T/dev/usr/include"
# Debian's headers and .pc files (amd64 packages; headers are the same on
# every architecture)
python3 -I - "$HERE/.." "$CACHE" "$T/hdr" <<'PY'
import subprocess, sys
sys.path.insert(0, sys.argv[1])
import debfetch
pkgs, _ = debfetch.packages(sys.argv[2], 'trixie', 'amd64')
for n in ['libgl-dev', 'libglx-dev', 'libgles-dev', 'libegl-dev', 'libopengl-dev', 'libglvnd-core-dev',
          'libglvnd-dev', 'libgbm-dev', 'mesa-common-dev']:
    subprocess.run(['dpkg-deb', '-x', debfetch.fetch(sys.argv[2], pkgs[n]), sys.argv[3]], check=True)
PY
cp -a "$T/hdr/usr/include/." "$T/dev/usr/include/"
for pc in "$T"/hdr/usr/lib/x86_64-linux-gnu/pkgconfig/*.pc; do
    sed "s|x86_64-linux-gnu|$MA|g" "$pc" > "$D/pkgconfig/$(basename "$pc")"
done
# the GL driver: one module under each soname (as guest/gl/build.sh does)
GL=$SRC/guest/gl
[ -f "$GL/gexgl.h" ] || { echo "gl-provider: no $GL/gexgl.h (run gex's guest/gl/build.sh once)" >&2; exit 1; }
[ -f "$GL/gl-extensions-generated.inc" ] || printf '%s\n' 'static const char *const gexgl_claimable_extensions[] = {0};' > "$T/gl-extensions-generated.inc"
[ -f "$GL/gl-aliases-generated.inc" ] || : > "$T/gl-aliases-generated.inc"
for so in libGLESv2.so.2 libEGL.so.1 libGL.so.1 libOpenGL.so.0 libGLX.so.0 libGLESv1_CM.so.1; do
    # (libGL and libGLX: with the GLX 1.4 entry points the driver lacks, glx-rest.c)
    rest=; case $so in libGL.so.1|libGLX.so.0) rest="$HERE/glx-rest.c" ;; esac
    GEXCC_SHARED=1 "$P/bin/gexcc" -shared -fPIC -O2 -I"$T" -I"$T/dev/usr/include" -o "$L/$so" -Wl,-soname,$so "$GL/gexgl.c" $rest -ldl
    ln -sf "$so" "$D/${so%.so.*}.so"
done
# GBM: every function of gbm.h, none with a device behind it
python3 -I - "$T/dev/usr/include/gbm.h" "$T/gbm.c" <<'PY'
import re, sys
h = open(sys.argv[1]).read()
h = re.sub(r'/\*.*?\*/', '', h, flags=re.S)
out = ['#include <gbm.h>', '#include <stddef.h>']
for m in re.finditer(r'\n([A-Za-z_][\w \*]*?[\s\*])(gbm_\w+)\s*\(([^;{]*?)\)\s*;', h):
    ret, name, args = m.group(1).strip(), m.group(2), m.group(3).strip()
    if 'typedef' in ret:
        continue
    # parameters stay as gbm.h writes them (an unnamed one is fine in C23)
    named = [args or 'void']
    body = ('' if ret == 'void' else 'return NULL;' if '*' in ret
            else f'{ret} r = {{0}}; return r;' if ret.split()[0] in ('union', 'struct') else 'return 0;')
    out.append(f'{ret} {name}({", ".join(named) or "void"}) {{ {body} }}')
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
PY
GEXCC_SHARED=1 "$P/bin/gexcc" -shared -fPIC -O2 -std=c23 -I"$T/dev/usr/include" -o "$L/libgbm.so.1" -Wl,-soname,libgbm.so.1 "$T/gbm.c"
ln -sf libgbm.so.1 "$D/libgbm.so"
names="libgl1, libgles2, libgles1, libegl1, libopengl0, libglx0, libglvnd0, libgbm1"
devnames="libgl-dev, libgles-dev, libegl-dev, libopengl-dev, libglx-dev, libglvnd-dev, libglvnd-core-dev, libgbm-dev, mesa-common-dev, libegl1-mesa-dev, libgl1-mesa-dev, libgles2-mesa-dev"
cat > "$T/lib/DEBIAN/control" <<EOF
Package: gex-gl
Version: $VER
Architecture: musl-linux-wasm32
Maintainer: gex-debian
Provides: $(echo "$names" | sed 's/, */ (= 99), /g; s/$/ (= 99)/')
Section: libs
Priority: optional
Description: OpenGL, EGL and GBM for gex (the guest GL driver)
 gex's guest GL driver, forwarding GL and EGL to the page's Mesa.
EOF
cat > "$T/dev/DEBIAN/control" <<EOF
Package: gex-gl-dev
Version: $VER
Architecture: musl-linux-wasm32
Maintainer: gex-debian
Depends: gex-gl (= $VER), libx11-dev
Provides: $(echo "$devnames" | sed 's/, */ (= 99), /g; s/$/ (= 99)/')
Section: libdevel
Priority: optional
Description: OpenGL, EGL and GBM headers for gex
 Khronos and GBM headers and pkg-config files, over gex's guest GL driver.
EOF
# its shlibs file: what a program linking one of the libraries depends on
for f in "$L"/*.so.*; do
    n=$(basename "$f"); echo "${n%%.so.*} ${n##*.so.} gex-gl (>= $VER)"
done > "$T/lib/DEBIAN/shlibs"
dpkg-deb --root-owner-group -b "$T/lib" "$W/debs/gex-gl_${VER}_musl-linux-wasm32.deb" >/dev/null
dpkg-deb --root-owner-group -b "$T/dev" "$W/debs/gex-gl-dev_${VER}_musl-linux-wasm32.deb" >/dev/null
echo "gex-gl $VER: $(ls "$L" | tr '\n' ' ')"
