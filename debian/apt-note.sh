#!/bin/sh
# apt's hooks for what the KDE image knows of a package it installs
# (mkrootfs.py writes them to /etc/apt/apt.conf.d/99gex-notes; the list is
# /usr/share/gex/apt-notes, `PACKAGE runtime | WHY | WHAT TO USE` lines):
#
#   apt-note --record   DPkg::Pre-Install-Pkgs, VersionInfo 3 on stdin:
#                       each package being installed that has a note, kept
#   apt-note --say      DPkg::Post-Invoke: those notes, said once dpkg is
#                       done, so they come after its output
#
# A hook that fails stops apt, so both end well whatever happens here.
notes=/usr/share/gex/apt-notes
kept=/var/lib/gex/apt-notes.pending
case ${1:-} in
--record)
    mkdir -p "${kept%/*}" 2>/dev/null
    # VersionInfo 3: apt's configuration up to an empty line, then a line per
    # package: NAME OLD-VERSION OLD-ARCH OLD-MA < NEW-VERSION NEW-ARCH NEW-MA
    # ACTION, the action the .deb's path when it is being unpacked
    awk -v notes="$notes" '
        BEGIN {
            while ((getline l < notes) > 0) {
                if (l ~ /^[ \t]*#/ || index(l, "|") == 0) continue
                split(l, f, "|"); n = split(f[1], h, " ")
                if (n >= 2 && h[2] == "runtime") {
                    why[h[1]] = f[2]; use[h[1]] = f[3]
                    gsub(/^[ \t]+|[ \t]+$/, "", why[h[1]]); gsub(/^[ \t]+|[ \t]+$/, "", use[h[1]])
                }
            }
        }
        body && NF >= 9 && $9 ~ /\.deb$/ && ($1 in why) && !said[$1]++ {
            printf "gex: %s is installed, and is known not to run here: %s (use %s)\n", $1, why[$1], use[$1]
        }
        /^$/ { body = 1 }' >> "$kept" 2>/dev/null
    ;;
--say)
    if [ -s "$kept" ]; then cat "$kept" >&2; fi
    rm -f "$kept"
    ;;
esac
exit 0
