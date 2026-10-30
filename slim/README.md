# debian-slim

A generic Debian trixie root filesystem for gex's runtime API: a base system
with apt ready to install more, D-Bus, and what X11 clients need, as one tar
(`debian-slim.tar`, and `.tar.zst`). It has no desktop, no init and no X
server: the runtime brings pid 1 and the X server.

## Contents

- Our `musl-linux-wasm32` packages (Debian's sources built with gexcc) first;
  Debian's `arm64` packages, which gex translates, for whatever ours do not
  have.
- The base system (bash, dash as `/bin/sh`, coreutils, util-linux, procps,
  less, ...), apt and dpkg, tzdata.
- D-Bus: the system bus and the session bus launcher.
- X11 clients' basics: libX11, libxcb, libXau, libXdmcp, libXext, libXrender,
  libXi, libXrandr, libXfixes, libXcursor; xkb-data; fontconfig with DejaVu;
  the DMZ cursor theme.
- `root`, and `user` (uid 1000, home `/home/user`). `/tmp` is 1777; `/run`,
  `/dev`, `/proc` and `/sys` are empty directories.
- No documentation or translations (dpkg path-exclude, which the image
  carries, so packages apt installs later leave them out too), and no
  function names in the wasm modules (`debian/stripnames.py`).

## Boot

The page runs `/etc/gex/boot` once (`System.spawn`), as root, before its
other programs. It starts the D-Bus system bus
(`/etc/gex/dbus-system.conf`: Debian's configuration, run as root).

## apt

dpkg's native architecture is `musl-linux-wasm32` and `arm64` is added as
the foreign one; apt takes both (`APT::Architectures`). Debian's archive
(`/etc/apt/sources.list.d/debian.sources`, arm64) is set up, with its
keyring in `/usr/share/keyrings/debian-archive-keyring.gpg`.

Our repository's address is not in the image: the host writes
`/etc/apt/sources.list.d/gex.list` at boot. The repository is not signed:

    deb [trusted=yes arch=musl-linux-wasm32,arm64] http://HOST/ trixie main

The image ships no package lists: `apt update` first, then `apt install`.
Our packages carry the library dependencies their cross build could not
compute (`debian/shlibdeps.py`).

## Building

    REPO_URL=http://gex-site/ OURS_FOR='*' DEB_CACHE=DIR GEXCC_PREFIX=DIR \
        slim/build-wasm32.sh OUT_DIR POOL...

POOL: directories of our .debs. Output: `OUT_DIR/debian-slim.tar`, and the
apt repository of every package of ours in `OUT_DIR/repo`, to serve where
`gex.list` points. The package list is `slim/roots.txt`.
