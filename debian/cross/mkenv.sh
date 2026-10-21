#!/bin/bash
# The environment Debian's own build (dpkg-buildpackage, debian/rules,
# debhelper) runs in to cross-build a package for musl-linux-wasm32 with gexcc.
#
#   debian/cross/mkenv.sh GEXCC_PREFIX ENVDIR
#   . ENVDIR/env.sh; dpkg-buildpackage -a musl-linux-wasm32 -d -B -uc -us
#
# What it makes, in ENVDIR:
#   host/   trixie's dpkg-dev, debhelper and pkg-kde-tools (architecture-
#           independent perl), unpacked: the build host's are older
#   dpkg/   dpkg's architecture tables with wasm32 in the CPU table, so
#           dpkg-architecture knows musl-linux-wasm32 (GNU type
#           wasm32-linux-musl); DPKG_DATADIR points here
#   bin/    gexcc's tools under the GNU type's names (wasm32-linux-musl-gcc,
#           -g++, -pkg-config, -ar...), which is what debhelper runs in a cross
#           build
#   env.sh  PATH, PERL5LIB, DPKG_DATADIR, and the cross defaults below
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
P=$(realpath "${1:?GEXCC_PREFIX}"); E=$(realpath -m "${2:?ENVDIR}")
CACHE=${DEB_CACHE:-$E/deb}
T=wasm32-unknown-linux-musl G=wasm32-linux-musl
mkdir -p "$E/host" "$E/dpkg" "$E/bin" "$CACHE"
python3 -I - "$HERE/.." "$CACHE" "$E/host" "$E/dpkg" <<'PY'
import os, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1])
import debfetch
cache, host, dpkgdir = sys.argv[2:5]
pkgs, _ = debfetch.packages(cache, 'trixie', 'arm64')
for n in ['dpkg-dev', 'libdpkg-perl', 'debhelper', 'libdebhelper-perl', 'dh-autoreconf',
          'pkg-kde-tools', 'libfile-stripnondeterminism-perl', 'dh-strip-nondeterminism']:
    subprocess.run(['dpkg-deb', '-x', debfetch.fetch(cache, pkgs[n]), host], check=True)
# the architecture tables are dpkg's (architecture-dependent package, data only)
with tempfile.TemporaryDirectory() as t:
    subprocess.run(['dpkg-deb', '-x', debfetch.fetch(cache, pkgs['dpkg']), t], check=True)
    for f in ('cputable', 'ostable', 'tupletable', 'abitable'):
        s = open(f'{t}/usr/share/dpkg/{f}').read()
        if f == 'cputable' and '\nwasm32' not in s:
            s += 'wasm32\t\twasm32\t\twasm32\t\t\t32\tlittle\n'
        open(f'{dpkgdir}/{f}', 'w').write(s)
for f in os.listdir(f'{host}/usr/share/dpkg'):
    p = f'{host}/usr/share/dpkg/{f}'
    if os.path.isfile(p):
        open(f'{dpkgdir}/{f}', 'wb').write(open(p, 'rb').read())
PY
# debhelper knows shared libraries by their ELF header. gexcc's are wasm side
# modules: dh_makeshlibs takes them too (their SONAME comes from gexcc's
# objdump), so a package's shlibs file is written as on any architecture
dh=$E/host/usr/share/perl5/Debian/Debhelper/Dh_Lib.pm
python3 -I - "$dh" "$E/host/usr/bin/dh_makeshlibs" <<'PY'
import sys
lib, mk = sys.argv[1:3]
s = open(lib).read()
if 'sub is_wasm_side_module' not in s:
    s = s.replace('sub is_so_or_exec_elf_file {', '''sub is_wasm_side_module {
	my ($file) = @_;
	open(my $fd, '<:raw', $file) or return 0;
	my $n = read($fd, my $buf, 4);
	close($fd);
	return ($n // 0) == 4 && $buf eq "\\0asm";
}

sub is_so_or_exec_elf_file {''', 1)
    s = s.replace('\tis_so_or_exec_elf_file\n', '\tis_so_or_exec_elf_file\n\tis_wasm_side_module\n', 1)
    open(lib, 'w').write(s)
m = open(mk).read()
m = m.replace('return if not is_so_or_exec_elf_file($_);',
              'return if not is_so_or_exec_elf_file($_) and not is_wasm_side_module($_);', 1)
open(mk, 'w').write(m)
PY
for t in gcc cc g++ c++ cpp clang clang++ ar ranlib nm objdump strings size readelf objcopy strip ld pkg-config; do
  src=$P/bin/$T-$t
  case $t in cpp) src=$P/bin/$T-gcc ;; ld) src=$P/bin/$T-ld ;; esac
  [ -e "$src" ] && ln -sfn "$src" "$E/bin/$G-$t"
done
cat > "$E/env.sh" <<ENV
# . this file: Debian's build tools, cross for musl-linux-wasm32 through gexcc
export PATH=$E/bin:$E/host/usr/bin:$P/bin:\$PATH
export PERL5LIB=$E/host/usr/share/perl5\${PERL5LIB:+:\$PERL5LIB}
export DPKG_DATADIR=$E/dpkg
export GEXCC_PREFIX=$P
# CMake (>= 3.21) reads the toolchain file from the environment: the sysroot
# and the search modes, under debhelper's own -D options
export CMAKE_TOOLCHAIN_FILE=$P/share/gexcc/toolchain.cmake
export CONFIG_SITE=$P/share/gexcc/config.site
ENV
echo "$E/env.sh"
