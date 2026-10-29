#!/bin/sh
# getent for an image without glibc's (libc-bin is left out: musl's
# programs read the files themselves). Maintainer scripts ask it whether a
# user or group exists (passwd's, adduser's) before they make one. The
# databases are the files, as nsswitch's "files" source reads them:
#
#   getent DATABASE [KEY...]
#
# passwd, group, shadow, gshadow (a KEY is a name, or for passwd and group
# a number), hosts (a name or an address), services (a name or a port),
# protocols (a name or a number). Exit 0 when every KEY was found, 2 when
# one was not, 1 for a database it does not know.
db=${1:-}
[ -n "$db" ] || { echo "Usage: getent DATABASE [KEY...]" >&2; exit 1; }
shift
case $db in
    passwd|group|shadow|gshadow) file=/etc/$db fs=: ;;
    hosts|services|protocols) file=/etc/$db fs=ws ;;
    *) echo "Unknown database: $db" >&2; exit 1 ;;
esac
[ -r "$file" ] || exit 2
if [ $# -eq 0 ]; then
    grep -v '^[[:space:]]*\(#\|$\)' "$file"
    exit 0
fi
rc=0
for key in "$@"; do
    awk -v db="$db" -v key="$key" -v fs="$fs" '
        BEGIN { if (fs == ":") FS = ":" }
        /^[ \t]*(#|$)/ { next }
        {
            line = $0; sub(/[ \t]*#.*/, "", line)
            if (fs == ":") {
                hit = $1 == key || ((db == "passwd" || db == "group") && key ~ /^[0-9]+$/ && $3 == key)
            } else if (db == "services") {
                split($2, pp, "/"); hit = $1 == key || pp[1] == key
                for (i = 3; !hit && i <= NF && $i !~ /^#/; i++) hit = $i == key
            } else {
                hit = 0
                for (i = 1; !hit && i <= NF && $i !~ /^#/; i++) hit = $i == key
            }
            if (hit) { print line; found = 1; exit }
        }
        END { exit !found }' "$file" || rc=2
done
exit $rc
