#!/usr/bin/env bash
# Regress Git --single-branch fetch/refspec behavior seen on the owner's Mac.
set -euo pipefail

tmp="$(/usr/bin/mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

git init --quiet --bare "$tmp/remote.git"
git init --quiet -b main "$tmp/source"
cd "$tmp/source"
git config user.name "Pairbar CI Fixture"
git config user.email "pairbar-ci@example.invalid"
printf 'base\n' > fixture.txt
git add fixture.txt
git commit --quiet -m base
git remote add origin "$tmp/remote.git"
git push --quiet origin main

git switch --quiet --create chatgpt/pairbar-resilient-profiles-20261116
printf 'hotfix\n' >> fixture.txt
git add fixture.txt
git commit --quiet -m hotfix
git push --quiet origin chatgpt/pairbar-resilient-profiles-20261116
git switch --quiet main
git merge --quiet --ff-only chatgpt/pairbar-resilient-profiles-20261116
git push --quiet origin main

git clone --quiet --single-branch --branch chatgpt/pairbar-resilient-profiles-20261116 \
    "$tmp/remote.git" "$tmp/checkout"
cd "$tmp/checkout"
# A manual fetch which creates origin/main does not update remote.origin.fetch.
git fetch --quiet origin main:refs/remotes/origin/main
git remote set-branches --add origin main
git fetch --quiet origin main
git switch --quiet --create main --track origin/main
test "$(git symbolic-ref --short HEAD)" = main
test "$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')" = origin/main
git merge-base --is-ancestor chatgpt/pairbar-resilient-profiles-20261116 main

echo "Single-branch origin/main tracking fixture PASS"
