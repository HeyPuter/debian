#!/bin/sh
# apt and apt-get in the KDE image (mkrootfs.py diverts them to
# /usr/lib/gex/NAME.real): the real program, then for each package an
# install named, what the image knows of it (/usr/share/gex/apt-notes) --
# why an install that failed cannot go ahead yet, or that one that worked
# is known not to run -- one line each.
real=/usr/lib/gex/${0##*/}.real
"$real" "$@"
rc=$?
case " $* " in
    *" install "*|*" reinstall "*) ;;
    *) exit $rc ;;
esac
# A package whose setup script (postinst) failed here stays half-configured,
# and then every later install stops on it too. Marked installed, said so,
# and the install tried once more: the rest of it goes ahead.
S=/var/lib/dpkg/status
tries=0
while [ $rc != 0 ] && [ $tries -lt 8 ] && grep -q '^Status: install ok half-configured$' "$S" 2>/dev/null; do
    tries=$((tries + 1))
    awk 'BEGIN { RS = ""; ORS = "\n\n" }
         /\nStatus: install ok half-configured(\n|$)/ {
             sub(/\nStatus: install ok half-configured/, "\nStatus: install ok installed")
             split($0, l, "\n"); for (i in l) if (l[i] ~ /^Package: /) n = substr(l[i], 10)
             for (i in l) if (l[i] ~ /^Architecture: /) a = substr(l[i], 15)
             print n ":" a > "/dev/stderr"
         }
         { print }' "$S" 2> "${TMPDIR:-/tmp}/gex-half.$$" > "$S.gex" && mv -f "$S.gex" "$S"
    while read -r p; do
        echo "gex: $p's setup script failed here; it is marked installed, and may not work" >&2
    done < "${TMPDIR:-/tmp}/gex-half.$$"
    rm -f "${TMPDIR:-/tmp}/gex-half.$$"
    "$real" "$@"
    rc=$?
done
notes=/usr/share/gex/apt-notes
# (a package with a note of its own failing is the reason, then: the rest
# of the command is not said to have failed on the holds)
pending=
for a in "$@"; do
    n=${a%%[:=/]*}
    grep -v '^#' "$notes" 2>/dev/null | awk -v n="$n" '$1 == n && $2 == "pending" { f = 1 } END { exit !f }' && pending=1
done
for a in "$@"; do
    case $a in -*|install|reinstall) continue ;; esac
    n=${a%%[:=/]*}
    line=$(grep -v '^#' "$notes" 2>/dev/null | awk -v n="$n" '$1 == n' | head -1)
    kind=$(printf '%s\n' "$line" | awk '{print $2}')
    why=$(printf '%s\n' "$line" | cut -d'|' -f2 | sed 's/^ *//; s/ *$//')
    fix=$(printf '%s\n' "$line" | cut -d'|' -f3 | sed 's/^ *//; s/ *$//')
    if [ $rc != 0 ]; then
        if [ "$kind" = pending ]; then
            echo "gex: $n cannot be installed yet: $why (coming: $fix)" >&2
        elif [ -n "$pending" ]; then
            :
        elif dpkg-query -W -f '${Status}' "$n" 2>/dev/null | grep -q ' installed$'; then
            :
        else
            echo "gex: $n was not installed: the desktop's own packages are held, and apt would have had to replace or remove one (apt-mark showhold)" >&2
        fi
    elif [ "$kind" = runtime ]; then
        echo "gex: $n is installed, and is known not to run here: $why (use $fix)" >&2
    fi
done
exit $rc
