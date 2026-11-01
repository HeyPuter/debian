#!/bin/sh
# The slim image's apt, set to install anything asked of it whatever it
# costs the packages already there (ours, wasm32, among them): what the
# overlay cannot say as files (build-wasm32.sh runs this on the tree, after
# the overlay).
#
#   slim/apt-anyway.sh TREE
#
# - Ours are not held: an install that needs Debian's arm64 build of one
#   in its place gets it.
# - Ours are preferred (our repository at 900, Debian's at 500) but not
#   imposed (1001 would downgrade to them), and no arm64 build of one of
#   our tools is refused (the KDE image's -1).
# The rest is the overlay's: etc/gex/apt-anyway and etc/gex/arm64-
# interpreters (usr/lib/gex/all-foreign reads them), the fail-safe
# maintainer scripts (usr/lib/gex/maint-safe, a dpkg hook), dpkg's
# database put right at boot and before apt update (usr/lib/gex/apt-heal),
# a no-op ldconfig, and apt.conf.d/90gex-anyway.
set -eu
T=${1:?TREE}
sed -i 's/^Status: hold ok installed$/Status: install ok installed/' "$T/var/lib/dpkg/status"
cat > "$T/etc/apt/preferences.d/gex-native" <<'PIN'
# Our packages (o=gex) before Debian's, but not at any cost: an install
# that needs Debian's arm64 build of one of ours in its place gets it
# (slim/apt-anyway.sh)
Package: *
Pin: release o=gex
Pin-Priority: 900
PIN
# the twins' pins are all-foreign's to write, at Debian's newest version
# where that is the later (it rewrites them after each apt update)
