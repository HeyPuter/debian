#!/bin/bash
# The tree's KService database (ksycoca), built into it under gex with the
# session's environment (the database's name hashes its directories), after
# every other change to the tree. XDG_MENU_PREFIX as startplasma sets it:
# the applications are indexed through the menu file it names
# (etc/xdg/menus/plasma-applications.menu), and without it the database has
# the MIME types and no application (Kickoff and the task manager's
# launchers then find none). KService rebuilds a database that is older
# than a directory or file it indexes, at session start, which under
# translation costs minutes. A build's last step before its tar.
#
#   kde/sycoca.sh TREE      (GEXC: gexc, default gexc on PATH)
#
# SOURCE_DATE_EPOCH (the builds set it): the same tree gives the same
# database. The database records the times of the files and directories it
# indexes, and its own as it is built: the tree's times are clamped to
# SOURCE_DATE_EPOCH first (as the tar that ships it clamps them), and its
# own is said as SOURCE_DATE_EPOCH. Nothing indexed is then newer than the
# database, so KService does not rebuild it at the session's start.
#
# A tree without kbuildsycoca6 (an ejected one keeps only what the session
# ran) borrows it from SYCOCA_TOOLS, a tree that has it (the arm64 build's
# tree), for the run.
set -eu
T=$(realpath "${1:?TREE}")
GEXC=${GEXC:-gexc}
rm -f "$T"/root/.cache/ksycoca6_*
mkdir -p "$T/root/.cache"
borrowed=
if [ ! -e "$T/usr/bin/kbuildsycoca6" ]; then
    tools=${SYCOCA_TOOLS:?a tree with usr/bin/kbuildsycoca6, as $T has none}
    t=$(stat -c %Y "$T/usr/bin")
    cp -a "$tools/usr/bin/kbuildsycoca6" "$T/usr/bin/"
    borrowed=$t
fi
sde=${SOURCE_DATE_EPOCH:-}
[ -z "$sde" ] || find "$T" -newermt "@$sde" -exec touch -h -d "@$sde" {} +
t0=$(date +%s)
"$GEXC" run --sysroot "$T" --uid 0 \
    --env HOME=/root --env XDG_RUNTIME_DIR=/tmp --env LANG=C.UTF-8 \
    --env XDG_DATA_DIRS=/usr/local/share:/usr/share --env XDG_CONFIG_DIRS=/etc/xdg \
    --env XDG_CURRENT_DESKTOP=KDE --env XDG_MENU_PREFIX=plasma- --env QT_QPA_PLATFORM=offscreen \
    "$T/usr/bin/kbuildsycoca6" --noincremental > /dev/null 2>&1 || true
if [ -n "$borrowed" ]; then
    rm "$T/usr/bin/kbuildsycoca6"
    touch -d "@$borrowed" "$T/usr/bin"
fi
db=$(ls "$T"/root/.cache/ksycoca6_* 2>/dev/null | head -1)
[ -n "$db" ] || { echo "kde/sycoca.sh: kbuildsycoca6 made no database in $T" >&2; exit 1; }
if [ -n "$sde" ]; then
    # the database's own time (its header's one quint64 of ms since the
    # epoch that falls in this run) said as SOURCE_DATE_EPOCH
    python3 -I - "$db" "$t0" "$(date +%s)" "$sde" <<'PY'
import struct, sys
db, t0, t1, sde = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
b = bytearray(open(db, 'rb').read())
at = [i for i in range(min(len(b), 4096) - 7) if (t0 - 1) * 1000 <= struct.unpack_from('>Q', b, i)[0] <= (t1 + 1) * 1000]
if len(at) != 1:
    sys.exit(f'kde/sycoca.sh: {len(at)} build times in the header of {db}, not one')
struct.pack_into('>Q', b, at[0], sde * 1000)
open(db, 'wb').write(b)
PY
    touch -h -d "@$sde" "$db" "$T/root/.cache" "$T/root" "$T/usr/bin"
fi
echo "$db"
