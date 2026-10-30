#!/bin/sh
# Debian's architecture-independent packages, for a system where Debian's
# arm64 programs run beside our musl-linux-wasm32 ones, and ours are dpkg's
# own (native) architecture. Run after every apt update and dpkg run
# (mkrootfs.py installs it with the apt hooks), on apt's Debian indexes and
# on dpkg's database:
#
#  - an Architecture: all package counts as the native architecture's, so
#    an arm64 program's dependency on Debian's data (okular on okular-data)
#    would need ours: it says Multi-Arch: foreign, which any architecture's
#    dependency is met by;
#  - its own dependencies count as the native architecture's too (dpkg-dev
#    on make, which we have no build of): one on a package of a single
#    architecture that ours have no package of is Debian's arm64 one,
#    `name:arm64`.
#
#   all-foreign.sh [--status] [ROOT]     (the system's root, default /)
#
# --status: dpkg's database only, with the names the last full run found
# (dpkg's hook: the indexes are as apt update left them)
set -u
only_status=
[ "${1:-}" = --status ] && { only_status=1; shift; }
R=${1:-}
L=$R/var/lib/apt/lists
S=$R/var/lib/dpkg/status
W=$R/var/lib/gex
mkdir -p "$W"
debian=$(ls "$L"/*_binary-arm64_Packages 2>/dev/null)
ours=$(ls "$L"/*_binary-musl-linux-wasm32_Packages 2>/dev/null)  # our repository, wherever it is served
# names: `o NAME` ours have (the package or a Provides of an installed or
# offered one of ours), `a NAME` any architecture's (Debian's
# Architecture: all or Multi-Arch: foreign packages and what they provide)
if [ -n "$only_status" ] && [ -f "$W/names" ]; then
    debian=
else
awk 'BEGIN { RS = ""; FS = "\n" }
function provides(line, kind,   n, i, p, a) {
    sub(/^Provides: /, "", line); n = split(line, p, ",")
    for (i = 1; i <= n; i++) { split(p[i], a, " "); sub(/:.*/, "", a[1]); if (a[1] != "") print kind, a[1] }
}
{
    name = ""; arch = ""; ma = ""; prov = ""
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^Package: /) name = substr($i, 10)
        else if ($i ~ /^Architecture: /) arch = substr($i, 15)
        else if ($i ~ /^Multi-Arch: /) ma = substr($i, 13)
        else if ($i ~ /^Provides: /) prov = $i
    }
    kind = ""
    if (arch == "musl-linux-wasm32") kind = "o"
    else if (arch == "all" || ma == "foreign") kind = "a"
    if (kind == "" || name == "") next
    print kind, name
    if (prov != "") provides(prov, kind)
}' $debian $ours "$S" | sort -u > "$W/names.new" && mv -f "$W/names.new" "$W/names"
fi
for f in $debian "$S"; do
    [ -f "$f" ] || continue
    awk -v names="$W/names" 'BEGIN {
        while ((getline l < names) > 0) { split(l, w, " "); if (w[1] == "o") ours[w[2]] = 1; else any[w[2]] = 1 }
        RS = ""; ORS = "\n\n"; FS = "\n"
    }
    function qualify(line, field,   rest, n, i, c, m, j, alt, nm, out, aout) {
        rest = substr(line, length(field) + 3); n = split(rest, c, ",")
        out = ""
        for (i = 1; i <= n; i++) {
            m = split(c[i], alt, "|"); aout = ""
            for (j = 1; j <= m; j++) {
                nm = alt[j]; sub(/^ +/, "", nm)
                split(nm, w, /[ (]/)
                if (w[1] !~ /:/ && !(w[1] in ours) && !(w[1] in any))
                    sub(/^[^ (]+/, w[1] ":arm64", nm)
                aout = aout (j > 1 ? " | " : "") nm
            }
            out = out (i > 1 ? ", " : "") aout
        }
        return field ": " out
    }
    function unany(line,   head, rest, out, nm, t) {
        head = line; sub(/: .*/, "", head)
        rest = substr(line, length(head) + 3); out = ""
        while (match(rest, /[a-z0-9][a-z0-9.+-]*:any/)) {
            nm = substr(rest, RSTART, RLENGTH - 4)
            t = substr(rest, RSTART, RLENGTH)
            out = out substr(rest, 1, RSTART - 1) ((nm in ours) ? nm : t)
            rest = substr(rest, RSTART + RLENGTH)
        }
        return head ": " out rest
    }
    {
        # ours, but a Multi-Arch: same library, meet any architecture'"'"'s
        # dependency (mkrootfs.py any_arch); dpkg writes what the .deb says
        if ($0 ~ /(^|\n)Architecture: musl-linux-wasm32(\n|$)/) {
            if ($0 ~ /(^|\n)Multi-Arch: same(\n|$)/) { print; next }
            if ($0 ~ /(^|\n)Multi-Arch: /) sub(/(^|\n)Multi-Arch: [a-z]+/, "\nMulti-Arch: foreign")
            else $0 = $0 "\nMulti-Arch: foreign"
            sub(/^\n/, "")
            print; next
        }
        # NAME:any (perl:any, python3:any) is met only by a Multi-Arch:
        # allowed package; ours say foreign, which a plain NAME is met by
        if ($0 ~ /:any/) {
            s = ""
            for (i = 1; i <= NF; i++) {
                l = $i
                if (l ~ /^(Pre-Depends|Depends|Recommends): /) l = unany(l)
                s = s (i > 1 ? "\n" : "") l
            }
            $0 = s
        }
        if ($0 !~ /(^|\n)Architecture: all(\n|$)/) { print; next }
        s = ""; hasma = 0
        for (i = 1; i <= NF; i++) {
            l = $i
            if (l ~ /^Multi-Arch: /) hasma = 1
            else if (l ~ /^Depends: /) l = qualify(l, "Depends")
            else if (l ~ /^Pre-Depends: /) l = qualify(l, "Pre-Depends")
            else if (l ~ /^Recommends: /) l = qualify(l, "Recommends")
            s = s (i > 1 ? "\n" : "") l
        }
        if (!hasma) s = s "\nMulti-Arch: foreign"
        print s
    }' "$f" > "$f.gex" && mv -f "$f.gex" "$f"
done
