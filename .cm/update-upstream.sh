#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "${ROOT}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Working tree is not clean. Commit or stash changes first.' >&2
  exit 1
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream https://github.com/fawney19/Aether.git
fi

echo '[1/3] Fetching official Aether main'
git fetch upstream main --tags

echo '[2/3] Merging official updates'
git merge --no-edit upstream/main

echo '[3/3] Official updates merged'
echo 'Review the changes, run .cm/build-linux-amd64.sh, then push to origin.'

