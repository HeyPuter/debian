#!/bin/bash
# The desktop demo's guest side: its base rootfs and its launcher's packages,
# written into the public tree gex's web/build-demo.sh stages from.
#
#   desktop/build-rootfs.sh [--no-rootfs] [--no-pkgs]
#
# 1. The base rootfs: bash and xterm and what they need, nothing else
#    (debian/mkrootfs.py over the gexcc pool, then pruned), as
#    $PUB/rootfs/base.tar.zst. Needs the pool rootfs/build-native-debian.sh
#    builds ($GEXCC_DEB/pool).
# 2. The launcher's packages (unless --no-pkgs): desktop/items.json, one
#    $PUB/pkgs/NAME.tar.zst per item plus pkgs/index.json, and $PUB/gex-apt
#    for an item with `lazypool`.
#
# PUB is gex's web/public ($GEX_SRC/web/public): an item's `files` (the GL
# marshallers) are read from it, and build-demo.sh stages from it.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PUB=${PUB:-${GEX_SRC:?set GEX_SRC to a gex checkout, or PUB to its web/public}/web/public}
export GEXCC_DEB=${GEXCC_DEB:-$HOME/gex-sandbox/scratch/CC/debian}
WORK=${GEX_DEMO_WORK:-$GEXCC_DEB/demo}
ITEMS=$HERE/items.json
# Our .debs are zstd (mkdebs.py): with xz, dpkg-deb's decoder was what
# dpkg waited on through every install (python3.13: about 470 ms of a 2.6 s
# reinstall). A pool packed before that still holds xz ones and would ship
# them without a word, so a stale one stops the build here.
stale=$(for f in "$GEXCC_DEB"/pool/*.deb; do
    [ -e "$f" ] || continue
    ar t "$f" | grep -qx 'data\.tar\.zst' || echo "  $(basename "$f")"
done)
if [ -n "$stale" ]; then
    echo "$GEXCC_DEB/pool has .debs that are not zstd; repack it with" >&2
    echo "  GEXCC_DEB=$GEXCC_DEB rootfs/build-native-debian.sh --repack" >&2
    echo "$stale" | head -5 >&2
    exit 1
fi
ROOTFS=1 PKGS=1
for a in "$@"; do
    case $a in
    --no-rootfs) ROOTFS=0 ;;
    --no-pkgs) PKGS=0 ;;
    *) echo "usage: desktop/build-rootfs.sh [--no-rootfs] [--no-pkgs]" >&2; exit 2 ;;
    esac
done
say() { printf '\n== %s\n' "$*"; }
size() { stat -c %s "$1"; }
mib() { awk -v n="$1" 'BEGIN { printf "%.1f MiB", n / 1048576 }'; }
command -v zstd >/dev/null || { echo "need zstd" >&2; exit 1; }
mkdir -p "$WORK" "$PUB/rootfs"

# -- 1. the base rootfs --------------------------------------------------------------
# What bash and xterm need, and the tools a shell user expects at the first
# prompt (user, 2026-10-11: "the base first-load should have coreutils at
# least"). All ours (wasm32, from Debian's sources). What each adds over
# bash + xterm, zstd -22 of its overlay (2026-10-11): coreutils 0.77 MiB,
# util-linux 0.57, procps 0.46, tar 0.41, nano 0.33, findutils 0.30,
# ncurses-bin 0.21, less 0.20, grep 0.17, sed 0.09, gzip 0.07, hostname
# 0.04, debianutils (run-parts, which: /etc/profile runs run-parts). Left to the launcher's "More tools": file 0.45, gawk 0.35,
# diffutils 0.32, zstd 0.21, xz-utils 0.14, bsdextrautils 0.13, tree 0.05.
# mawk and sysvinit-utils (0.2 MB) are there because base-files wants an awk
# and x11-common an lsb-base; dash is /bin/sh (dpkg, scripts).
BASE_ROOTS=base-files,base-passwd,ncurses-base
BASE_EXTRA=xterm
BASE_OURS=bash,dash,mawk,sysvinit-utils,coreutils,grep,sed,findutils,procps,less,ncurses-bin,gzip,tar,util-linux,hostname,nano,debianutils
# Pruned after: fonts xterm does not use (its default font is the X server's
# own `fixed`; DejaVu Sans Mono stays for `xterm -fa`), Xlib's locales but C
# and en_US.UTF-8, icons and menus.
base_prune() { # base_prune TREE
    local t=$1
    rm -f "$t"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf "$t"/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
          "$t"/usr/share/fonts/truetype/dejavu/DejaVuSerif*.ttf
    for l in "$t"/usr/share/X11/locale/*; do
        case ${l##*/} in C|en_US.UTF-8|iso8859-1|locale.alias|locale.dir|compose.dir) ;; *) rm -rf "$l" ;; esac
    done
    # locale.dir and compose.dir name every locale; keep their C and en_US lines
    for f in locale.dir compose.dir; do
        [ -f "$t/usr/share/X11/locale/$f" ] || continue
        grep -E '^(#|$)|(^| )(C|en_US\.UTF-8|iso8859-1)/' "$t/usr/share/X11/locale/$f" > "$t/usr/share/X11/locale/$f.n" || true
        mv "$t/usr/share/X11/locale/$f.n" "$t/usr/share/X11/locale/$f"
    done
    # (debconf and its perl stay: maintainer scripts source
    # /usr/share/debconf/confmodule, and a dpkg -i or apt install runs them)
    rm -rf "$t"/usr/share/icons "$t"/usr/share/pixmaps "$t"/usr/share/applications \
           "$t"/usr/share/man "$t"/usr/share/doc-base "$t"/usr/share/lintian "$t"/usr/share/bash-completion \
           2>/dev/null || true
}
if [ "$ROOTFS" = 1 ]; then
    say "base rootfs"
    python3 -I "$ROOT/debian/mkrootfs.py" --pool "$GEXCC_DEB/pool" --out "$WORK/base" \
        --roots "$BASE_ROOTS" --extra "$BASE_EXTRA" --ours "$BASE_OURS"
    base_prune "$WORK/base"
    tar -C "$WORK/base" --owner=0 --group=0 --numeric-owner --sort=name -cf "$WORK/base.tar" .
    zstd --ultra -22 -T0 -q -f "$WORK/base.tar" -o "$PUB/rootfs/base.tar.zst"
    echo "  base: $(mib "$(du -sb --apparent-size "$WORK/base" | cut -f1)") tree," \
         "$(mib "$(size "$WORK/base.tar")") tar, $(mib "$(size "$PUB/rootfs/base.tar.zst")") zstd"
fi

# -- 2. the launcher's packages --------------------------------------------------------------
# desktop/items.json: one overlay per distinct `pkg` (default the item's id),
# made by mkrootfs.py as the base plus the item and diffed against the base
# (debian/mkoverlay.py), pruned as the base is. pkgs/index.json is
# what the launcher lists. DEMO_DEBS=ID,... also writes pkgs/ID-debs.tar.zst:
# the .debs of what that overlay adds, under /var/cache/apt/archives (the
# dpkg -i measurement, docs/gexcc.md §9).
if [ "$PKGS" = 1 ]; then
    say "launcher packages"
    mkdir -p "$PUB/pkgs" "$WORK/pkgs"
    python3 -I - "$ITEMS" > "$WORK/pkgs/list" <<'PY'
import json, sys
seen = set()
for it in json.load(open(sys.argv[1]))['items']:
    pkg = it.get('pkg', it['id'])
    if pkg in seen: continue
    seen.add(pkg)
    print(pkg, it.get('roots', '-'), it.get('extra', '-') or '-', it.get('ours', '-') or '-')
PY
    while read -r pkg roots extra ours; do
        [ "$roots" = - ] && roots=$BASE_ROOTS || roots=$BASE_ROOTS,$roots
        [ "$extra" = - ] && extra=$BASE_EXTRA || extra=$BASE_EXTRA,$extra
        [ "$ours" = - ] && ours=$BASE_OURS || ours=$BASE_OURS,$ours
        t=$WORK/pkgs/$pkg
        python3 -I "$ROOT/debian/mkrootfs.py" --pool "$GEXCC_DEB/pool" --out "$t" \
            --roots "$roots" --extra "$extra" --ours "$ours" 2>"$WORK/pkgs/$pkg.log" ||
            { cat "$WORK/pkgs/$pkg.log"; exit 1; }
        base_prune "$t"
        # The item's own `prune` (globs under the tree) and `files` (guest
        # path -> a file under $PUB), e.g. gears: Debian's Mesa out, the
        # gex GL marshallers in.
        GEXCC_DEB=$GEXCC_DEB python3 -I - "$ITEMS" "$pkg" "$t" "$PUB" <<'PY'
import glob, json, os, shutil, sys
items, pkg, tree, pub = json.load(open(sys.argv[1]))['items'], sys.argv[2], sys.argv[3], sys.argv[4]
it = next(x for x in items if x.get('pkg', x['id']) == pkg)
for g in it.get('prune', []):
    for p in glob.glob(os.path.join(tree, g)):
        shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.unlink(p)
# `lazypool`: our own .debs (the gex apt repository, /var/lib/gex-apt) as
# files the guest fetches from the page when apt reads them, so apt can
# install a dependency only we build (bsdextrautils for man-db...) without
# the overlay carrying the whole pool. They are published under gex-apt/.
if it.get('lazypool'):
    pool = os.path.join(os.environ['GEXCC_DEB'], 'pool')
    lazy = []
    for f in sorted(os.listdir(pool)):
        if not f.endswith('.deb'):
            continue
        name = f.split('_')[0]
        rel = f'pool/main/{name[0]}/{name}/{f}'
        out = os.path.join(pub, 'gex-apt', rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        shutil.copy(os.path.join(pool, f), out)
        lazy.append([f'/var/lib/gex-apt/{rel}', os.path.getsize(out), f'gex-apt/{rel}'])
    d = os.path.join(tree, 'var/lib/gex-overlay')
    os.makedirs(d, exist_ok=True)
    json.dump(lazy, open(os.path.join(d, f'{pkg}.lazy'), 'w'))
for dst, src in it.get('files', {}).items():
    d = os.path.join(tree, dst.lstrip('/'))
    os.makedirs(os.path.dirname(d), exist_ok=True)
    shutil.copy(os.path.join(pub, src), d)
    os.chmod(d, 0o755)
PY
        python3 -I "$ROOT/debian/mkoverlay.py" --base "$WORK/base" --tree "$t" --name "$pkg" \
            --tar "$WORK/pkgs/$pkg.tar" | tee "$WORK/pkgs/$pkg.added"
        zstd --ultra -22 -T0 -q -f "$WORK/pkgs/$pkg.tar" -o "$PUB/pkgs/$pkg.tar.zst"
        echo "  $pkg: $(mib "$(size "$WORK/pkgs/$pkg.tar")") tar, $(mib "$(size "$PUB/pkgs/$pkg.tar.zst")") zstd"
        case ,${DEMO_DEBS:-}, in *,$pkg,*)
            d=$WORK/pkgs/$pkg-debs; rm -rf "$d"; mkdir -p "$d/var/cache/apt/archives"
            for n in $(sed 's/^[^:]*: [0-9]* paths, [0-9]* packages: //' "$WORK/pkgs/$pkg.added"); do
                f=$(ls "$GEXCC_DEB/pool/${n}_"*.deb 2>/dev/null | head -1)
                [ -n "$f" ] || f=$(find "$HOME/gex-sandbox/scratch/CC/deb/pool" -name "${n}_*_*.deb" | head -1)
                [ -n "$f" ] || { echo "  no .deb for $n" >&2; continue; }
                cp "$f" "$d/var/cache/apt/archives/"
            done
            tar -C "$d" --owner=0 --group=0 --numeric-owner -cf "$WORK/pkgs/$pkg-debs.tar" .
            zstd --ultra -22 -T0 -q -f "$WORK/pkgs/$pkg-debs.tar" -o "$PUB/pkgs/$pkg-debs.tar.zst"
            echo "  $pkg-debs: $(ls "$d/var/cache/apt/archives" | wc -l) debs, $(mib "$(size "$PUB/pkgs/$pkg-debs.tar.zst")") zstd"
        esac
    done < "$WORK/pkgs/list"
    python3 -I - "$ITEMS" "$PUB/pkgs" > "$PUB/pkgs/index.json" <<'PY'
import json, os, sys
items = json.load(open(sys.argv[1]))['items']
out = []
for it in items:
    pkg = it.get('pkg', it['id'])
    o = {k: it[k] for k in ('id', 'label', 'desc', 'glyph', 'color', 'cmd', 'auto', 'gl') if k in it}
    o['pkg'] = pkg
    o['size'] = os.path.getsize(os.path.join(sys.argv[2], pkg + '.tar.zst'))
    out.append(o)
# The .deb bundles (DEMO_DEBS), for a measurement rather than the launcher.
hidden = [{'id': f[:-len('.tar.zst')], 'pkg': f[:-len('.tar.zst')], 'cmd': 'true',
           'size': os.path.getsize(os.path.join(sys.argv[2], f))}
          for f in sorted(os.listdir(sys.argv[2])) if f.endswith('-debs.tar.zst')]
print(json.dumps({'items': out, 'hidden': hidden}, indent=1))
PY
fi

