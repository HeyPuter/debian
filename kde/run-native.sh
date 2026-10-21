#!/bin/bash
# The KDE session natively, on gexc's own compositor: for debugging only (the
# browser is the target). Frames go to OUT/frames (one in GEX_PPM_EVERY), the
# session's log to OUT/log.
#
#   kde/run-native.sh TREE OUT [gexc] [WxH]     (GEXC_ARGS: more gexc run options, e.g. --strace)
set -u
tree=$(realpath "${1:?TREE}"); out=$(realpath -m "${2:?OUT}")
gexc=${3:-${GEX_SRC:?set GEX_SRC or pass gexc}/target/release/gexc}
size=${4:-1280x800}
mkdir -p "$out/frames"
GEX_PPM_EVERY=${GEX_PPM_EVERY:-50} timeout -k 10 "${TMO:-1800}" "$gexc" run --sysroot "$tree" --uid 0 \
    --wayland /tmp/gex-kde-wl --wayland-size "$size" --wayland-out "$out/frames/f" \
    --bind "$out=/out" --env GEX_KDE_XWAYLAND=1 --env GEX_KDE_LOG=/out --env "GEX_KDE_GEOMETRY=$size" \
    ${GEXC_ARGS:-} "$tree/usr/bin/bash" /usr/local/bin/gex-kde-session > "$out/log" 2>&1
echo "exit $?"
