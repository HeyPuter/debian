#!/bin/bash
# fetch-pin.sh REPO COMMIT DIR: DIR checked out at COMMIT (detached), by a
# shallow fetch of that one commit; nothing is done when DIR is already there.
# With SUBMODULES="path ..." those submodules are fetched shallow too.
set -euo pipefail
repo=$1 commit=$2 dir=$3
if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" != "$commit" ]; then
  mkdir -p "$dir"
  [ -d "$dir/.git" ] || git -C "$dir" init -q
  git -C "$dir" remote remove origin 2>/dev/null || true
  git -C "$dir" remote add origin "$repo"
  echo "fetch-pin: $repo $commit"
  git -C "$dir" fetch -q --depth 1 origin "$commit"
  git -C "$dir" -c advice.detachedHead=false checkout -q --force FETCH_HEAD
  [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || { echo "fetch-pin: $dir is not at $commit" >&2; exit 1; }
fi
for s in ${SUBMODULES:-}; do
  git -C "$dir" submodule update -q --init --depth 1 -- "$s"
done
