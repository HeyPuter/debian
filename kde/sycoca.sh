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
echo "$db"
