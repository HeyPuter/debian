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

## The release image

The released slim image is built as above with:

- Pools in this order: the base system's cross build, the KDE image's
  build, the rebuilds of packages fixed since, and the X clients' build.
  Where pools hold a package at two versions, the higher one wins, so a
  pool must not carry a stale package at a higher version than its rebuild:
  the old ICU debs at `76.1-4+gex1` (from before the change list dropped
  that suffix) outrank the filtered rebuild at `76.1-4` and are left out of
  the pools (a pool can be a directory of links to the debs it takes).
- `GEXCC_PREFIX` set to the gexcc the packages were built with: its libc
  goes into the image, and an older one than the packages' (apt-get exits
  127) or a newer one breaks them.
- `GEX_LEAK_CHECK=warn` while some packages still carry the build machine's
  home directory in a path; the check fails the build otherwise.
- `REPO_URL` and `OURS_FOR='*'`, so `OUT_DIR/repo` has every package of
  ours for apt to install later.

What it gives: a 106 MB tar, 20 MB compressed (`.tar.zst`). With the
repository served and Debian reached through the network, `apt-get update`
and `apt-get install` work for our packages and Debian's arm64 ones
(`nodejs`, `python3`, `git`, `x11-utils`, `x11-xkb-utils`), and the X
clients they bring open their windows.
