#!/bin/sh
# apt and dpkg made robust in an image (the KDE image and slim), with no
# change to what apt chooses: the files of debian/apt-hooks/ laid over the
# tree, and no byte-compiling of python modules at install.
#
#   debian/apt-hooks.sh TREE
#
# - Every maintainer script fail-safe (usr/lib/gex/maint-safe, a dpkg
#   pre-invoke hook): one package's failing script never leaves dpkg unable
#   to install the next.
# - dpkg's database put right after an install that stopped part way
#   (usr/lib/gex/apt-heal): before apt-get update, and at the image's start
#   (slim's /etc/gex/boot, the KDE session's gex-kde-session).
# - No py3compile or py3clean (dpkg.cfg.d/gex-no-pycompile keeps later
#   packages' copies out, and the ones in the tree go here): python compiles
#   a module when it is first imported.
set -eu
T=${1:?TREE}
HERE=$(cd "$(dirname "$0")" && pwd)
ex=; [ -L "$T/bin" ] && ex=--exclude=./bin
tar -C "$HERE/apt-hooks" $ex -cf - . | tar -C "$T" --keep-directory-symlink -xf -
rm -f "$T/usr/bin/py3compile" "$T/usr/bin/py3clean"
