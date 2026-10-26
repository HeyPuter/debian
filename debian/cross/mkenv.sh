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
# dpkg-gensymbols and dpkg-shlibdeps likewise: a side module is an object,
# all of one format (its symbols come from gexcc's objdump)
python3 -I - "$E/host/usr/share/perl5/Dpkg/Shlibs/Objdump.pm" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if 'WASM:32' not in s:
    s = s.replace('''    return unless $elf{magic} eq "\\x7fELF";''',
                  '''    return $format{$file} = 'WASM:32:l:wasm32:0' if $elf{magic} eq "\\0asm";
    return unless $elf{magic} eq "\\x7fELF";''', 1)
    s = s.replace('''$result = 1 if ($header =~ /^\\177ELF$/);''',
                  '''$result = 1 if ($header =~ /^\\177ELF$/ or $header eq "\\0asm");''', 1)
    assert s.count('WASM:32') == 1 and s.count('"\\0asm"') == 2, 'Objdump.pm changed'
    open(p, 'w').write(s)
PY
# and a program, the module in its ELF container (right after the ELF
# header and the program headers)
python3 -I - "$E/host/usr/share/perl5/Dpkg/Shlibs/Objdump.pm" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if 'ELF container' not in s:
    s = s.replace("    my $rc = read $fh, $header, 64;", "    my $rc = read $fh, $header, 4096;", 1)
    s = s.replace("    } elsif ($rc != 64) {", "    } elsif ($rc < 64) {", 1)
    s = s.replace("""    return unless $elf{magic} eq "\\x7fELF";""",
                  """    # a gexcc program: the wasm module in its ELF container
    return $format{$file} = 'WASM:32:l:wasm32:0'
        if $elf{magic} eq "\\x7fELF" and index($header, "\\0asm\\x01\\0\\0\\0") > 0;
    return unless $elf{magic} eq "\\x7fELF";""", 1)
    assert 'read $fh, $header, 4096' in s and '$rc < 64' in s and s.count('WASM:32') == 2, 'Objdump.pm changed'
    open(p, 'w').write(s)
PY
# dh_shlibdeps takes an ELF file that is not statically linked (by file(1));
# a side module, and a program's container (which file(1) calls static),
# are both dynamically linked wasm
python3 -I - "$E/host/usr/bin/dh_shlibdeps" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if 'gexcc' not in s:
    old = """		return 1 if $ff =~ m/ELF/ && $ff !~ /statically linked/;
		return 0;"""
    new = """		return 1 if $ff =~ m/ELF/ && $ff !~ /statically linked/;
		# gexcc's: a side module, or a program's ELF container
		open(my $fd, '<:raw', $file) or return 0;
		my $n = read($fd, my $head, 4096);
		close($fd);
		return 1 if ($n // 0) >= 8 and (substr($head, 0, 4) eq "\\0asm" or (substr($head, 0, 4) eq "\\x7fELF" and index($head, "\\0asm\\x01\\0\\0\\0") > 0 and index($head, 'dylink.0') > 0));
		return 0;"""
    assert s.count(old) == 1, 'dh_shlibdeps changed'
    s = s.replace(old, new, 1)
    old = "				return if not is_so_or_exec_elf_file($fn);"
    assert s.count(old) == 1, 'dh_shlibdeps changed'
    s = s.replace(old, "				return if not is_so_or_exec_elf_file($fn) and not is_wasm_side_module($fn);", 1)
    open(p, 'w').write(s)
PY
for t in gcc cc g++ c++ cpp clang clang++ ar ranlib nm objdump strings size readelf objcopy strip ld pkg-config; do
  src=$P/bin/$T-$t
  case $t in cpp) src=$P/bin/$T-gcc ;; ld) src=$P/bin/$T-ld ;; esac
  [ -e "$src" ] && ln -sfn "$src" "$E/bin/$G-$t"
done
# pkg-config: gexcc's, over the sysroot; and, as Debian's cross pkg-config
# also searches it, the build machine's /usr/share/pkgconfig for a package
# the sysroot has no .pc of (libwayland-bin's wayland-scanner.pc, whose
# pkgdatadir is where ECM's FindWayland takes wayland.xml from: a Multi-Arch:
# foreign package, so only the chroot has it)
rm -f "$E/bin/$G-pkg-config"
cat > "$E/bin/$G-pkg-config" <<SH
#!/bin/sh
"$P/bin/$T-pkg-config" "\$@" && exit 0
st=\$?
for a; do
    case \$a in -*) ;; *) PKG_CONFIG_LIBDIR=/usr/share/pkgconfig PKG_CONFIG_PATH= pkg-config --exists "\$a" 2>/dev/null || exit \$st ;; esac
done
exec env PKG_CONFIG_LIBDIR=/usr/share/pkgconfig PKG_CONFIG_PATH= pkg-config "\$@"
SH
chmod +x "$E/bin/$G-pkg-config"
# meson, with cuts.txt's options for the source being built after the
# package's own (meson takes the last -D of an option)
cat > "$E/bin/meson" <<'SH'
#!/bin/sh
if [ "${1:-}" = setup ] && [ -n "${GEXCC_MESON_INIT:-}" ]; then
    shift
    set -- setup "$@" $(cat "$GEXCC_MESON_INIT")
fi
exec /usr/bin/meson "$@"
SH
chmod +x "$E/bin/meson"
# chrpath: a gexcc container has no ELF dynamic section (its run path is
# in the wasm module's dylink.0), so `chrpath -d` on one (sqlite3's tcl
# module) has nothing to delete; any other file, and any other use, is the
# real chrpath's
cat > "$E/bin/chrpath" <<'SH'
#!/bin/sh
# (in-chroot.sh binds this over /usr/bin/chrpath, and the real one here)
real=/usr/lib/gex-cross/chrpath
[ -x "$real" ] || real=/usr/bin/chrpath
case " $* " in
*" -d "*|*" --delete "*)
    for f; do
        case $f in -*) continue ;; esac
        [ -f "$f" ] || continue
        if head -c 1048576 "$f" | grep -aq 'dylink\.0' && ! readelf -d "$f" 2>/dev/null | grep -q 'Dynamic section'; then
            continue
        fi
        "$real" -d "$f" || exit
    done
    exit 0 ;;
esac
exec "$real" "$@"
SH
chmod +x "$E/bin/chrpath"
# patchelf --remove-rpath (libcap2's test programs), likewise: a gexcc
# container has no dynamic section for patchelf to edit
cat > "$E/bin/patchelf" <<'SH'
#!/bin/sh
# (in-chroot.sh binds this over /usr/bin/patchelf, and the real one here)
real=/usr/lib/gex-cross/patchelf
[ -x "$real" ] || real=/usr/bin/patchelf
case " $* " in
*" --remove-rpath "*)
    for f; do
        case $f in -*) continue ;; esac
        [ -f "$f" ] || continue
        if head -c 1048576 "$f" | grep -aq 'dylink\.0' && ! readelf -d "$f" 2>/dev/null | grep -q 'Dynamic section'; then
            continue
        fi
        "$real" --remove-rpath "$f" || exit
    done
    exit 0 ;;
esac
exec "$real" "$@"
SH
chmod +x "$E/bin/patchelf"
# dh_qmldeps: qt6-declarative's rules run it with LD_LIBRARY_PATH at the
# libraries just built, so the build machine's qmlimportscanner would load
# them; in a cross build they are the target's (wasm) and no build-machine
# program can load them, so the scanner keeps its own. (Found on PATH
# first; the real one stays where it is, next to the helper it runs.)
cat > "$E/bin/dh_qmldeps" <<'SH'
#!/bin/sh
unset LD_LIBRARY_PATH
exec /usr/bin/dh_qmldeps "$@"
SH
chmod +x "$E/bin/dh_qmldeps"
# dpkg-query: a query naming a package of the target architecture
# (PKG:musl-linux-wasm32) is answered from the sysroot's package database,
# which xbuild keeps as it unpacks the target's packages there, and so is a
# search for one of the target's paths (dh_qmldeps looks up the qmldir files
# of the QML modules a module imports); any other, from the build machine's
cat > "$E/bin/dpkg-query" <<SH
#!/bin/sh
for a; do
    case \$a in *:musl-linux-wasm32|*/wasm32-linux-musl/*) exec /usr/bin/dpkg-query --admindir=$P/sysroot/var/lib/dpkg "\$@" ;; esac
done
exec /usr/bin/dpkg-query "\$@"
SH
chmod +x "$E/bin/dpkg-query"
# cmake: gexcc's toolchain file (the sysroot and the search modes, under
# debhelper's own -D options) for a configure debhelper runs for the
# target, which it marks with CMAKE_SYSTEM_PROCESSOR; not through the
# environment, where a project's own build of a tool for the build machine
# (kf6-syntax-highlighting's ExternalProject of katehighlightingindexer)
# would take it too and cross-compile itself again, without end
cat > "$E/bin/cmake" <<SH
#!/bin/sh
for a; do
    case \$a in -DCMAKE_SYSTEM_PROCESSOR=wasm32) exec /usr/bin/cmake -DCMAKE_TOOLCHAIN_FILE=$P/share/gexcc/toolchain.cmake "\$@" ;; esac
done
exec /usr/bin/cmake "\$@"
SH
chmod +x "$E/bin/cmake"
cat > "$E/env.sh" <<ENV
# . this file: Debian's build tools, cross for musl-linux-wasm32 through gexcc
export PATH=$E/bin:$E/host/usr/bin:$P/bin:\$PATH
export PERL5LIB=$E/host/usr/share/perl5\${PERL5LIB:+:\$PERL5LIB}
export DPKG_DATADIR=$E/dpkg
export GEXCC_PREFIX=$P
export CONFIG_SITE=$P/share/gexcc/config.site
ENV
echo "$E/env.sh"
