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
# gexcc-exec's machine-wide slots (at most GEXCC_SLOTS gexcs at once): the
# host's slot files, so builds in here count against the same limit
slots=${GEXCC_SLOT_DIR:-${XDG_RUNTIME_DIR:-/tmp}/gexcc-slots-$(id -u)}
mkdir -p "$slots"
# debhelper names the cross pkg-config by its full path (PKG_CONFIG=
# /usr/bin/TRIPLET-pkg-config), as crossbuild-essential installs it
for t in "$E"/bin/*-pkg-config; do
    [ -e "$t" ] && ln -sfn "$t" "$C/usr/bin/$(basename "$t")"
done
exec bwrap --unshare-user --uid 0 --gid 0 --unshare-ipc --unshare-pid --die-with-parent \
    --bind "$C" / --dev /dev --proc /proc --tmpfs /tmp \
    --ro-bind "$LLVM" "$LLVM" --tmpfs /usr/local/bin "${tools[@]}" \
    --bind "$P" "$P" --bind "$E" "$E" "${extra[@]}" "${binds[@]}" \
    --bind "$slots" "$slots" --setenv GEXCC_SLOT_DIR "$slots" \
    --setenv HOME /root --setenv LANG C.UTF-8 --setenv LC_ALL C.UTF-8 --unsetenv LANGUAGE --chdir "$cwd" \
    /bin/bash -c '. "$0"/env.sh; exec "$@"' "$E" "$@"
