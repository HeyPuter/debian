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
# $R/etc/gex/arm64-interpreters (an image may carry it): interpreters of
# ours whose plugins are native code (perlapi-*, a versioned python3). An
# arm64 package's dependency on one is Debian's arm64 build, not ours: its
# XS module or extension only loads into an arm64 interpreter, so apt
# brings that one in (in place of ours) rather than leave a plugin ours
# cannot load. A line `NAME <<`: only a dependency with an upper bound
# (python3 (<< 3.14), which dh_python3 gives a compiled extension; a
# script's python3:any or plain python3 stays met by ours).
interp=
interp_lt=
if [ -f "$R/etc/gex/arm64-interpreters" ]; then
    interp=$(grep -v '^#' "$R/etc/gex/arm64-interpreters" | awk 'NF == 1 {print $1}' | paste -sd'|')
    interp_lt=$(grep -v '^#' "$R/etc/gex/arm64-interpreters" | awk 'NF == 2 && $2 == "<<" {print $1}' | paste -sd'|')
fi
# $R/etc/gex/apt-anyway (an image may carry it): an install goes through
# whatever it costs ours. In our packages (our index and dpkg's database):
# none is Essential, so apt may put Debian's arm64 build of one in its
# place (perl-base:arm64 for an arm64 perl module), and one of ours that
# needs another at an exact version (perl on perl-base, a library's -dev on
# it) needs ours, so the two change architecture together.
anyway=
[ -f "$R/etc/gex/apt-anyway" ] && anyway=1
# apt-anyway: the Multi-Arch: same libraries of ours (a full run: from our index)
if [ -n "$anyway" ] && [ -z "$only_status" ] && [ -n "$ours" ]; then
    awk 'BEGIN { RS = ""; FS = "\n" }
    /(^|\n)Multi-Arch: same(\n|$)/ { for (i = 1; i <= NF; i++) if ($i ~ /^Package: /) print substr($i, 10) }' $ours | sort -u > "$W/same.new" && mv -f "$W/same.new" "$W/same"
fi
[ -f "$W/same" ] || : > "$W/same"
rewrite=$debian
[ -n "$anyway" ] && [ -z "$only_status" ] && rewrite="$debian $ours"
for f in $rewrite "$S"; do
    [ -f "$f" ] || continue
    # the expressions through the environment: awk -v would read their \. as an escape
    GEX_INTERP=$interp GEX_INTERP_LT=$interp_lt awk -v names="$W/names" -v same_f="$W/same" -v anyway="$anyway" 'BEGIN {
        interp = ENVIRON["GEX_INTERP"]; interp_lt = ENVIRON["GEX_INTERP_LT"]
        while ((getline l < same_f) > 0) same[l] = 1
        while ((getline l < names) > 0) { split(l, w, " "); if (w[1] == "o") ours[w[2]] = 1; else any[w[2]] = 1 }
        RS = ""; ORS = "\n\n"; FS = "\n"
    }
    function qualify(line, field,   rest, n, i, c, m, j, alt, nm, out, aout) {
        rest = substr(line, length(field) + 3); n = split(rest, c, ",")
        out = ""
        for (i = 1; i <= n; i++) {
            m = split(c[i], alt, "|"); aout = ""
            for (j = 1; j <= m; j++) {
                nm = alt[j]; sub(/^ +/, "", nm); if (anyway) sub(/ +$/, "", nm)  # (KDE: as it was)
                split(nm, w, /[ (]/)
                if (w[1] !~ /:/ && !(w[1] in ours) && !(w[1] in any))
                    sub(/^[^ (]+/, w[1] ":arm64", nm)
                aout = aout (j > 1 ? " | " : "") nm
            }
            out = out (i > 1 ? ", " : "") aout
        }
        return field ": " out
    }
    function toarm(line,   head, rest, n, i, c, m, j, alt, nm, w, out, aout) {
        head = line; sub(/: .*/, "", head)
        rest = substr(line, length(head) + 3); n = split(rest, c, ",")
        out = ""
        for (i = 1; i <= n; i++) {
            m = split(c[i], alt, "|"); aout = ""
            for (j = 1; j <= m; j++) {
                nm = alt[j]; sub(/^ +/, "", nm); sub(/ +$/, "", nm)
                split(nm, w, /[ (]/)
                if (w[1] !~ /:/ && ((interp != "" && w[1] ~ ("^(" interp ")$")) || (interp_lt != "" && nm ~ /\(<< / && w[1] ~ ("^(" interp_lt ")$"))))
                    sub(/^[^ (]+/, w[1] ":arm64", nm)
                aout = aout (j > 1 ? " | " : "") nm
            }
            out = out (i > 1 ? ", " : " ") aout
        }
        return head ":" out
    }
    function tonative(line,   head, rest, n, i, c, m, j, alt, nm, w, out, aout, k) {
        head = line; sub(/: .*/, "", head)
        rest = substr(line, length(head) + 3); n = split(rest, c, ",")
        out = ""
        for (i = 1; i <= n; i++) {
            m = split(c[i], alt, "|"); aout = ""
            for (j = 1; j <= m; j++) {
                nm = alt[j]; sub(/^ +/, "", nm); sub(/ +$/, "", nm)
                split(nm, w, /[ (]/)
                if (w[1] !~ /:/ && nm ~ /\(= / && (w[1] in ours))
                    sub(/^[^ (]+/, w[1] ":musl-linux-wasm32", nm)
                # a Multi-Arch: same library of ours says its twin'"'"'s newer
                # version once Debian moves on (below): at least the version
                k = w[1]; sub(/:musl-linux-wasm32$/, "", k)
                if ((k in same) && nm ~ /\(= /) sub(/\(= /, "(>= ", nm)
                aout = aout (j > 1 ? " | " : "") nm
            }
            out = out (i > 1 ? ", " : " ") aout
        }
        return head ":" out
    }
    function unany(line,   head, rest, out, nm, t) {
        head = line; sub(/: .*/, "", head)
        rest = substr(line, length(head) + 3); out = ""
        while (match(rest, /[a-z0-9][a-z0-9.+-]*:any/)) {
            nm = substr(rest, RSTART, RLENGTH - 4)
            t = substr(rest, RSTART, RLENGTH)
            out = out substr(rest, 1, RSTART - 1) ((anyway || (nm in ours)) ? nm : t)
            rest = substr(rest, RSTART + RLENGTH)
        }
        return head ": " out rest
    }
    {
        # ours, but a Multi-Arch: same library, meet any architecture'"'"'s
        # dependency (mkrootfs.py any_arch); dpkg writes what the .deb says
        if ($0 ~ /(^|\n)Architecture: musl-linux-wasm32(\n|$)/) {
            if (anyway) {
                gsub(/(^|\n)Essential: yes(\n|$)/, "\n"); sub(/^\n/, ""); sub(/\n$/, "")
                s = ""
                for (i = 1; i <= NF; i++) {
                    l = $i
                    if (l ~ /^(Pre-Depends|Depends): /) l = tonative(l)
                    s = s (i > 1 ? "\n" : "") l
                }
                $0 = s
            }
            # ours say foreign here, so a NAME:any of ours (libgio-2.0-dev-bin
            # on python3:any) is met by none: a plain NAME (apt-anyway; the
            # KDE image as it was)
            if (anyway && $0 ~ /:any/) {
                s = ""
                for (i = 1; i <= NF; i++) {
                    l = $i
                    if (l ~ /^(Pre-Depends|Depends|Recommends): /) l = unany(l)
                    s = s (i > 1 ? "\n" : "") l
                }
                $0 = s
            }
            if ($0 ~ /(^|\n)Multi-Arch: same(\n|$)/) { print; next }
            if ($0 ~ /(^|\n)Multi-Arch: /) sub(/(^|\n)Multi-Arch: [a-z]+/, "\nMulti-Arch: foreign")
            else $0 = $0 "\nMulti-Arch: foreign"
            sub(/^\n/, "")
            print; next
        }
        if ((interp != "" || interp_lt != "") && $0 ~ /(^|\n)Architecture: arm64(\n|$)/) {
            s = ""
            for (i = 1; i <= NF; i++) {
                l = $i
                if (l ~ /^(Pre-Depends|Depends): /) l = toarm(l)
                s = s (i > 1 ? "\n" : "") l
            }
            $0 = s
        }
        # apt-anyway: the arm64 build of a package from Debian (not a
        # Multi-Arch: same library) meets a dependency on its name from any
        # architecture, as ours do: where ours of that name cannot be had
        # (perl next to an arm64 perl-base), apt takes the one from Debian
        if (anyway && $0 ~ /(^|\n)Architecture: arm64(\n|$)/ && $0 !~ /(^|\n)Multi-Arch: same(\n|$)/) {
            if ($0 ~ /(^|\n)Multi-Arch: /) sub(/(^|\n)Multi-Arch: [a-z]+/, "\nMulti-Arch: foreign")
            else $0 = $0 "\nMulti-Arch: foreign"
            sub(/^\n/, "")
        }
        # NAME:any (perl:any, python3:any) is met only by a Multi-Arch:
        # allowed package; ours say foreign, which a plain NAME is met by
        # (apt-anyway: every NAME, as Debian'"'"'s say foreign too)
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
# apt-anyway, after an update: a Multi-Arch: same library of ours and
# Debian's arm64 build of it must be at one version (dpkg and apt both
# hold them to it), and Debian moves on (a security update) where ours does
# not. So ours says, in dpkg's database, Debian's newest version where that
# is the later (the code is ours as built; the library's interface is
# the same), and apt's pin of the arm64 build (/etc/apt/preferences.d/
# gex-twins) is to that version: an arm64 package that needs Debian's
# newest gets it beside ours.
if [ -n "$anyway" ] && [ -z "$only_status" ] && [ -n "$debian" ]; then
    awk -v status="$S" -v ourlist="$ours" -v twins="$W/twins" -v bump="$W/twins.bump" -v idx="$W/twins.idx" '
    # the version order of dpkg (lib/dpkg/version.c)
    function order(c) {
        if (c == "~") return -1
        if (c ~ /[0-9]/) return 0
        if (c == "") return 0
        if (c ~ /[A-Za-z]/) return index("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", c)
        return 256 + index("!\"#$%&'"'"'()*+,-./:;<=>?@[\\]^_`{|}", c)
    }
    function verrevcmp(a, b,   fd, ac, bc, d) {
        while (a != "" || b != "") {
            fd = 0
            while ((a != "" && substr(a, 1, 1) !~ /[0-9]/) || (b != "" && substr(b, 1, 1) !~ /[0-9]/)) {
                ac = order(substr(a, 1, 1)); bc = order(substr(b, 1, 1))
                if (ac != bc) return ac - bc
                a = substr(a, 2); b = substr(b, 2)
            }
            while (substr(a, 1, 1) == "0") a = substr(a, 2)
            while (substr(b, 1, 1) == "0") b = substr(b, 2)
            while (substr(a, 1, 1) ~ /[0-9]/ && substr(b, 1, 1) ~ /[0-9]/) {
                if (!fd) fd = substr(a, 1, 1) - substr(b, 1, 1)
                a = substr(a, 2); b = substr(b, 2)
            }
            if (substr(a, 1, 1) ~ /[0-9]/) return 1
            if (substr(b, 1, 1) ~ /[0-9]/) return -1
            if (fd) return fd
        }
        return 0
    }
    function vcmp(x, y,   ex, ey, ux, uy, rx, ry, r) {
        ex = 0; ey = 0
        if (x ~ /^[0-9]+:/) { ex = substr(x, 1, index(x, ":") - 1) + 0; x = substr(x, index(x, ":") + 1) }
        if (y ~ /^[0-9]+:/) { ey = substr(y, 1, index(y, ":") - 1) + 0; y = substr(y, index(y, ":") + 1) }
        if (ex != ey) return ex - ey
        ux = x; rx = ""; if (match(x, /-[^-]*$/)) { ux = substr(x, 1, RSTART - 1); rx = substr(x, RSTART + 1) }
        uy = y; ry = ""; if (match(y, /-[^-]*$/)) { uy = substr(y, 1, RSTART - 1); ry = substr(y, RSTART + 1) }
        r = verrevcmp(ux, uy); if (r) return r
        return verrevcmp(rx, ry)
    }
    BEGIN { RS = ""; FS = "\n" }
    {
        n = ""; v = ""; a = ""; ma = ""; st = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^Package: /) n = substr($i, 10)
            else if ($i ~ /^Version: /) v = substr($i, 10)
            else if ($i ~ /^Architecture: /) a = substr($i, 15)
            else if ($i ~ /^Multi-Arch: /) ma = substr($i, 13)
            else if ($i ~ /^Status: /) st = $i
        }
        if (FILENAME == status) {
            if (a == "musl-linux-wasm32" && ma == "same" && st ~ / (installed|unpacked|half-configured)$/) { inst[n] = v; ours[n] = v }
        } else if (a == "musl-linux-wasm32") {
            if (ma == "same" && !(n in inst)) ours[n] = v
        } else if (a == "arm64") {
            if (!(n in deb) || vcmp(v, deb[n]) > 0) deb[n] = v
        }
    }
    END {
        print "# Debian'"'"'s arm64 build of each Multi-Arch: same library of ours, at the" > twins
        print "# version ours says (usr/lib/gex/all-foreign, apt-anyway)\n" > twins
        printf "" > bump; printf "" > idx
        for (n in ours) {
            v = ours[n]
            if ((n in deb) && vcmp(deb[n], v) > 0) { v = deb[n]; if (n in inst) print n, v > bump; print n, v > idx }
            printf "Package: %s:arm64\nPin: version %s\nPin-Priority: 1001\n\n", n, v > twins
        }
    }' "$S" $ours $debian
    mv -f "$W/twins" "$R/etc/apt/preferences.d/gex-twins"
    # and our index says it too, for one of ours not installed yet: apt then
    # puts ours in beside the arm64 build already at Debian's newer version
    # (libpcre2-16-0 for libqt6core6t64); dpkg unpacks ours as built, and
    # dpkg's hook (--status, below) gives it the twin's version before the
    # two are configured
    if [ -s "$W/twins.idx" ]; then
        for f in $ours; do
            awk -v idx="$W/twins.idx" 'BEGIN {
                while ((getline l < idx) > 0) { split(l, w, " "); b[w[1]] = w[2] }
                RS = ""; ORS = "\n\n"; FS = "\n"
            }
            {
                n = ""; for (i = 1; i <= NF; i++) if ($i ~ /^Package: /) n = substr($i, 10)
                if ((n in b) && $0 ~ /(^|\n)Multi-Arch: same(\n|$)/)
                    sub(/(^|\n)Version: [^\n]*/, "\nVersion: " b[n])
                sub(/^\n/, "")
                print
            }' "$f" > "$f.gex" && mv -f "$f.gex" "$f"
        done
    fi
fi
# apt-anyway, after dpkg: a library of ours installed since the update
# (libevent-2.1-7t64 by one install, then thunderbird wanting Debian's
# newer arm64 build beside it) says the version its twin is pinned to, as
# the update would have made it say
if [ -n "$anyway" ] && [ -n "$only_status" ] && [ -f "$R/etc/apt/preferences.d/gex-twins" ]; then
    awk -v status="$S" -v bump="$W/twins.bump" '
    BEGIN { printf "" > bump }
    FILENAME != status && /^Package: / { n = substr($2, 1, index($2, ":") - 1); next }
    FILENAME != status && /^Pin: version / { pin[n] = $3; next }
    FILENAME == status && /^Package: / { n = $2; v = ""; a = ""; ma = ""; st = "" }
    FILENAME == status && /^Version: / { v = $2 }
    FILENAME == status && /^Architecture: / { a = $2 }
    FILENAME == status && /^Multi-Arch: / { ma = $2 }
    FILENAME == status && /^Status: / { st = $0 }
    FILENAME == status && /^$/ { check() }
    function check() {
        if (a == "musl-linux-wasm32" && ma == "same" && st ~ / (installed|unpacked|half-configured)$/ && (n in pin) && pin[n] != v) print n, pin[n] > bump
        n = ""
    }
    END { if (n != "") check() }' "$R/etc/apt/preferences.d/gex-twins" "$S"
fi
# apt-anyway, after an update or dpkg: one of ours that needs another of
# ours at its exact version (perl on perl-base) cannot go in once Debian's
# arm64 build of that other has taken its place (perl-base:arm64 for an
# XS module), and apt, asked for the name, takes ours and gives up. So ours
# of such a name are refused (pinned at -1), and apt takes Debian's arm64
# build of it. Also everything of ours that needs one of those exactly.
if [ -n "$anyway" ] && [ -n "$ours" ]; then
    awk -v status="$S" '
    BEGIN { RS = ""; FS = "\n" }
    {
        n = ""; a = ""; st = ""; dep = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^Package: /) n = substr($i, 10)
            else if ($i ~ /^Architecture: /) a = substr($i, 15)
            else if ($i ~ /^Status: /) st = $i
            else if ($i ~ /^(Pre-Depends|Depends): /) dep = dep ", " substr($i, index($i, ": ") + 2)
        }
        if (FILENAME == status) {
            if (st !~ / installed$/) next
            if (a == "musl-linux-wasm32") native[n] = 1
            else if (a == "arm64") arm[n] = 1
            next
        }
        if (a != "musl-linux-wasm32") next
        ours[n] = 1
        if ($0 ~ /(^|\n)Multi-Arch: same(\n|$)/) same[n] = 1
        k = split(dep, c, /[,|]/)
        for (j = 1; j <= k; j++)
            if (match(c[j], /[a-z0-9][a-z0-9.+-]*:musl-linux-wasm32 \(= /)) {
                m = substr(c[j], RSTART, RLENGTH); sub(/:.*/, "", m)
                needs[n] = needs[n] " " m
            }
    }
    END {
        for (n in arm) if ((n in ours) && !(n in native) && !(n in same)) gone[n] = 1
        do {
            more = 0
            for (n in needs) {
                if ((n in gone) || (n in native)) continue
                k = split(needs[n], w, " ")
                for (j = 1; j <= k; j++) if (w[j] in gone) { gone[n] = 1; more = 1; break }
            }
        } while (more)
        print "# ours that cannot go in beside Debian'"'"'s arm64 builds installed in"
        print "# their place: apt takes the arm64 build (usr/lib/gex/all-foreign)\n"
        for (n in gone) printf "Package: %s:musl-linux-wasm32\nPin: version *\nPin-Priority: -1\n\n", n
    }' "$S" $ours > "$W/gone" && mv -f "$W/gone" "$R/etc/apt/preferences.d/gex-gone"
fi
if [ -n "$anyway" ] && [ -s "$W/twins.bump" ]; then
    {
        awk -v bump="$W/twins.bump" 'BEGIN {
            while ((getline l < bump) > 0) { split(l, w, " "); b[w[1]] = w[2] }
            RS = ""; ORS = "\n\n"; FS = "\n"
        }
        {
            n = ""; for (i = 1; i <= NF; i++) if ($i ~ /^Package: /) n = substr($i, 10)
            if ((n in b) && $0 ~ /(^|\n)Architecture: musl-linux-wasm32(\n|$)/ && $0 ~ /(^|\n)Multi-Arch: same(\n|$)/)
                sub(/(^|\n)Version: [^\n]*/, "\nVersion: " b[n])
            sub(/^\n/, "")
            print
        }' "$S" > "$S.gex" && mv -f "$S.gex" "$S"
    }
    : > "$W/twins.bump"
fi
