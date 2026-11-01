#!/usr/bin/env bash
#
# Commit an edit of the pointer files to main while main may be moving.
#
#   scripts/commit-to-main.sh "latest.json: tiles-20261101" COMMAND [ARG...]
#
# Each attempt fetches main into a fresh worktree, runs COMMAND there (the
# worktree is its working directory), commits whatever it changed and pushes.
# A rejected push starts over from the new main, so the command always edits
# the files as they are now: publish-tiles and publish-gazetteer both write
# pointers, hours apart or not, and neither rebases a stale edit over the
# other's. A command that changes nothing commits nothing.
set -euo pipefail

[ "$#" -ge 2 ] || { echo "usage: $0 MESSAGE COMMAND [ARG...]" >&2; exit 2; }
msg="$1"; shift
repo="$(git rev-parse --show-toplevel)"
tree="$(mktemp -d)/main"
cleanup() { git -C "$repo" worktree remove --force "$tree" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for attempt in 1 2 3 4 5; do
  cleanup
  git -C "$repo" fetch --quiet origin main
  git -C "$repo" worktree add --quiet --detach "$tree" FETCH_HEAD
  (cd "$tree" && "$@")
  git -C "$tree" add -A
  if git -C "$tree" diff --cached --quiet; then
    echo "nothing to commit for: $msg"
    exit 0
  fi
  git -C "$tree" -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -m "$msg"
  if git -C "$tree" push --quiet origin HEAD:main; then
    echo "pushed: $msg"
    exit 0
  fi
  echo "push rejected on attempt $attempt (main moved?); starting over" >&2
  sleep $(( attempt * 5 ))
done
echo "could not push: $msg" >&2
exit 1
