# debian

Debian root filesystems for [gex](https://github.com/MercuryWorkshop/gex), and
the demos built on them. gex runs them in the browser: Debian's own arm64
binaries translated, and Debian's sources built with gex's `gexcc` into native
wasm32 programs.

- `debian/`: Debian trixie source packages built with gexcc into `.deb`s
  (`build.sh`, `recipes.sh`, `packages.txt`, `mkdebs.py`), and the rootfs
  assembler (`mkrootfs.py`: Debian's arm64 closure plus ours, a dpkg database,
  apt set up for both), with `debfetch.py`/`debsrc.py` verifying everything
  against Debian's signed indexes.
- `rootfs/`: the image builders (`build-debian.sh`, `build-native-debian.sh`,
  `build-session-tree.sh`, `build-graphics-rootfs.sh`, `manifests/`).
- `desktop/`: the desktop demo's base rootfs and launcher packages, for gex's
  `web/build-demo.sh`.

`make help` lists the targets. gex is fetched at the commit in `pins.mk`, or
set `GEX_DIR` in `local.mk` to a checkout of your own.
