#!/bin/bash
# Run a command in the cross build's chroot (mkchroot.sh) without root:
# bubblewrap with a user namespace, uid 0 inside. The host's clang and
# wasm-ld (gexcc calls them by name), the gexcc prefix, the cross environment
# (mkenv.sh) and the gexc that runs wasm32 programs are bound in at their own
# paths, so env.sh and the toolchain's baked paths hold inside too.
#
#   debian/cross/in-chroot.sh CHROOT GEXCC_PREFIX ENVDIR [--bind DIR]... -- CMD...
#
# CMD runs with ENVDIR/env.sh sourced, in the first --bind DIR (or /).
# Environment: GEXC (the gexc wasm32 programs run under; default the
# prefix's runner), LLVM (default /usr/lib/llvm-22).
set -eu
# this directory, read-only inside: files cuts.txt names (@CROSS@)
HERE=$(cd "$(dirname "$0")" && pwd)
C=$(realpath "${1:?CHROOT}"); P=$(realpath "${2:?GEXCC_PREFIX}"); E=$(realpath "${3:?ENVDIR}")
shift 3
binds=() cwd=/
while [ $# -gt 0 ] && [ "$1" != -- ]; do
    case $1 in
        --bind) d=$(realpath "$2"); binds+=(--bind "$d" "$d"); [ "$cwd" = / ] && cwd=$d; shift 2 ;;
        *) echo "in-chroot.sh: unknown option $1" >&2; exit 2 ;;
    esac
done
[ "${1:-}" = -- ] && shift
[ $# -gt 0 ] || { echo "usage: in-chroot.sh CHROOT GEXCC_PREFIX ENVDIR [--bind DIR]... -- CMD..." >&2; exit 2; }
LLVM=${LLVM:-/usr/lib/llvm-22}
tools=()
# clang, clang++, wasm-ld and the binutils gexcc names, as the host has them
for t in clang clang++ wasm-ld llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-objdump llvm-strip llvm-readelf llvm-size llvm-strings; do
    h=$(command -v "$t" 2>/dev/null) || continue
    # a link to the real binary under LLVM, so its $ORIGIN/../lib finds libLLVM
    tools+=(--symlink "$(realpath "$h")" "/usr/local/bin/$t")
done
# LLVM's own libraries live in the multiarch dir, linked from LLVM/lib
for l in "$LLVM"/lib/lib*.so.*; do
    r=$(realpath "$l")
    case $r in "$LLVM"/*) ;; *) tools+=(--ro-bind "$r" "$r") ;; esac
done
gexc=${GEXC:-$(cat "$P/lib/gexcc/runner" 2>/dev/null || true)}
extra=()
[ -n "$gexc" ] && [ -e "$gexc" ] && extra+=(--ro-bind "$(realpath "$gexc")" "$(realpath "$gexc")")
# gexcc-exec is a script naming the real gexc; bind what it names as well
if [ -n "$gexc" ] && [ -f "$gexc" ] && head -c2 "$gexc" | grep -q '#!'; then
    for g in $(grep -oE '/[^ "'"'"']*gexc\b' "$gexc" | sort -u); do
        [ -e "$g" ] && extra+=(--ro-bind "$g" "$g")
    done
fi
# the host libraries the gexc links that the chroot lacks (libGLESv2...)
for g in $(printf '%s\n' "${extra[@]}" | grep '^/' | sort -u); do
    for l in $(ldd "$g" 2>/dev/null | awk '$3 ~ /^\// {print $3}'); do
        [ -e "$C$l" ] || [ -e "$C/usr$l" ] || extra+=(--ro-bind "$(realpath "$l")" "/usr$l")
    done
done
# the environment's architecture tables (wasm32 in the CPU table) at dpkg's
# own path as well: python-debian reads /usr/share/dpkg whatever DPKG_DATADIR
# says, and debputy, matching each package's Architecture against an
# architecture it does not know, built none of the linux-any ones
# (util-linux's libmount-dev)
for t in cputable ostable abitable tupletable; do
    [ -e "$E/dpkg/$t" ] && extra+=(--ro-bind "$E/dpkg/$t" "/usr/share/dpkg/$t")
done
# the environment's chrpath, patchelf and dh_qmldeps at the tools' own paths
# too: debian/rules name /usr/bin/chrpath (exiv2's); the real ones move aside
for t in chrpath patchelf dh_qmldeps; do
    [ -e "$C/usr/bin/$t" ] && [ -e "$E/bin/$t" ] &&
        extra+=(--ro-bind "$C/usr/bin/$t" "/usr/lib/gex-cross/$t" --ro-bind "$E/bin/$t" "/usr/bin/$t")
done
# gexcc-exec's machine-wide slots (at most GEXCC_SLOTS gexcs at once): the
# host's slot files, so builds in here count against the same limit
slots=${GEXCC_SLOT_DIR:-${XDG_RUNTIME_DIR:-/tmp}/gexcc-slots-$(id -u)}
mkdir -p "$slots"
# debhelper names the cross pkg-config by its full path (PKG_CONFIG=
# /usr/bin/TRIPLET-pkg-config), as crossbuild-essential installs it
for t in "$E"/bin/*-pkg-config; do
    [ -e "$t" ] && ln -sfn "$t" "$C/usr/bin/$(basename "$t")"
done
# the target's multiarch directories at the paths a Debian cross build has
# them (debian/rules name /usr/lib/TRIPLET/tcl8.6 and the like): the sysroot's
for d in usr/lib/wasm32-linux-musl usr/include/wasm32-linux-musl; do
    mkdir -p "$P/sysroot/$d"
    [ -d "$C/$d" ] && [ ! -L "$C/$d" ] || ln -sfn "$P/sysroot/$d" "$C/$d"
done
exec bwrap --unshare-user --uid 0 --gid 0 --unshare-ipc --unshare-pid --die-with-parent \
    --bind "$C" / --dev /dev --proc /proc --tmpfs /tmp \
    --ro-bind "$LLVM" "$LLVM" --tmpfs /usr/local/bin "${tools[@]}" \
    --bind "$P" "$P" --bind "$E" "$E" --ro-bind "$HERE" "$HERE" "${extra[@]}" "${binds[@]}" \
    --bind "$slots" "$slots" --setenv GEXCC_SLOT_DIR "$slots" \
    --setenv HOME /root --setenv LANG C.UTF-8 --setenv LC_ALL C.UTF-8 --unsetenv LANGUAGE --chdir "$cwd" \
    /bin/bash -c '. "$0"/env.sh; exec "$@"' "$E" "$@"
