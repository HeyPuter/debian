#!/bin/bash
# The first bundle's file list from the release sweep (kde/sweep.py): each
# run of a one-bundle SITE records the files its session used
# (test-page.mjs KDE_OPENED), up to the desktop and then to the run's end;
# the list is the desktop's files in the order the session first used them,
# then the rest of every run's, then every file of kde/overlay (ours, small,
# and read by programs everywhere: a run of an older image never saw a new
# one), each once. mksite.sh OPENED takes it. SITE must be a one-bundle site
# or one whose first bundle already has every run's files.
#
#   kde/coverage.sh SITE OUTDIR    (writes OUTDIR/first-bundle.txt)
#
# Runs test-page.mjs here (node, Chrome as test-page.mjs finds it). RUN=CMD:
# a command each run is given to instead, as `CMD INPUT DIR` (a bench host's
# wrapper), which must leave DIR/opened.txt and DIR/opened.txt.end.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SITE=$1; OUT=$(realpath -m "$2"); mkdir -p "$OUT"
for kind in kcm apps; do
    input=$(python3 -I "$HERE/sweep.py" $kind)
    if [ -n "${RUN:-}" ]; then
        $RUN "$input" "$OUT/$kind"
    else
        mkdir -p "$OUT/$kind"
        KDE_INPUT="$input" KDE_OPENED="$OUT/$kind/opened.txt" KDE_WALL=2700 KDE_AFTER=10 \
            node "$HERE/test-page.mjs" "$SITE" "$OUT/$kind" > "$OUT/$kind/run.out" 2>&1 || true
    fi
done
{ cat "$OUT"/kcm/opened.txt "$OUT"/apps/opened.txt "$OUT"/kcm/opened.txt.end "$OUT"/apps/opened.txt.end
  (cd "$HERE/overlay" && find . -type f | sed 's/^\.//' | sort); } |
    grep -vE '^/(run|tmp|proc|dev|sys)/|^/root/rs\.sh$|org\.kp\.rs|kp-test|^/root/\.config/session/' |  # the sweep's own
    awk 'NF && !seen[$0]++' > "$OUT/first-bundle.txt"
echo "$OUT/first-bundle.txt: $(wc -l < "$OUT/first-bundle.txt") files"
