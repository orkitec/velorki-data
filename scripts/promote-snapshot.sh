#!/usr/bin/env bash
#
# After a gazetteer run: make its snapshot the one apps follow once it is
# complete, then prune old snapshots.
#
# Called by .github/workflows/publish-gazetteer.yml right after
# publish-gazetteer.sh, whether that succeeded or not; runnable locally with
# `gh` authenticated and push rights on main.
#
#   pending.json (written by publish-tiles) names a snapshot whose rd5 tiles are
#   uploaded. If TAG is that snapshot:
#     1. this run's regions are folded into pending.json's gazetteer state
#        (scripts/snapshot.py state): a world run records the regions it
#        missed, a custom run strikes the ones it built;
#     2. with no region missing, the snapshot is checked tile by tile against
#        its releases and the live snapshot (snapshot.py check);
#     3. if complete, latest.json becomes pending.json in one commit and
#        pending.json goes; otherwise pending.json keeps the state and the
#        script fails, saying what is missing. latest.json is not touched.
#   A TAG that is not pending (a re-run for the live snapshot, a next.json
#   snapshot) is published into and nothing moves.
#   Pruning runs last, from main's pointers as they are after the commit.
#
#   Quarantined tiles (publish-gazetteer.sh carried last month's .gaz over for
#   them, or they had none) do not hold the snapshot back: every tile has data.
#   They are recorded in the pointer (gazetteer.carriedOver / .quarantined) and
#   the script fails after promoting and pruning, so the run shows red.
#
#   REHEARSAL=1 does all of this on rehearsal/*.json and rehearsal-* releases
#   only; the real pointers and tiles-* releases are never read or touched.
set -uo pipefail

: "${GH_REPO:?GH_REPO must be set, e.g. orkitec/velorki-data}"
: "${TAG:?TAG must name the snapshot this run published into}"
SCOPE="${SCOPE:-world}"
# Written by publish-gazetteer.sh when it got to the end: {"built": [...], "missing": [...]}.
RESULT_FILE="${RESULT_FILE:?RESULT_FILE must be set}"
KEEP_RELEASES="${KEEP_RELEASES:-2}"
RUN_URL="${RUN_URL:-}"
WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/promote}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ "${REHEARSAL:-0}" = "1" ]; then
  POINTER_DIR="rehearsal/"; TAG_PREFIX="rehearsal-"
else
  POINTER_DIR=""; TAG_PREFIX="tiles-"
fi
case "$TAG" in
  "$TAG_PREFIX"*) ;;
  *) echo "TAG $TAG is not a $TAG_PREFIX* snapshot (REHEARSAL=${REHEARSAL:-0}); nothing to promote" >&2; exit 1 ;;
esac

log() { printf '%s [promote] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR" || exit 1

# main's pointer files as they are now (this mode's: rehearsal/ in a
# rehearsal), into $1 under their plain names.
main_pointers() {
  local f
  mkdir -p "$1"; rm -f "$1"/*.json "$1"/keep-tags.txt
  git fetch --quiet origin main || return 1
  for f in latest.json pending.json next.json keep-tags.txt; do
    git show "FETCH_HEAD:$POINTER_DIR$f" > "$1/$f" 2>/dev/null || rm -f "$1/$f"
  done
}

prune() {
  log "pruning: keeping the pointers' snapshots, keep-tags.txt and the newest $KEEP_RELEASES"
  main_pointers "$WORK_DIR/after" || { log "could not read main; not pruning"; return 1; }
  python3 "$HERE/snapshot.py" prune --dir "$WORK_DIR/after" --repo "$GH_REPO" \
    --keep "$KEEP_RELEASES" --tag-prefix "$TAG_PREFIX"
}

finish() {
  local rc="$1" prune_rc=0
  prune || prune_rc=$?
  [ "$prune_rc" = "0" ] || log "WARNING pruning did not finish"
  exit "$rc"
}

if [ ! -f "$RESULT_FILE" ]; then
  log "publish-gazetteer.sh did not finish; pending.json and latest.json stay as they are"
  echo "Publishing did not finish: nothing recorded, latest.json unchanged." >> "$SUMMARY"
  exit 0
fi

main_pointers "$WORK_DIR/before" || { log "could not fetch main"; exit 1; }
# Tiles publish-gazetteer.sh quarantined: they fail the run, after the rest.
n_quarantined="$(python3 -c '
import json, sys
result = json.load(open(sys.argv[1]))
print(len(result.get("carriedOver", {})) + len(result.get("quarantined", {})))
' "$RESULT_FILE")" || n_quarantined=0
ok=0
[ "$n_quarantined" = "0" ] || ok=1

pending_tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "$WORK_DIR/before/pending.json" 2>/dev/null || true)"
if [ "$pending_tag" != "$TAG" ]; then
  log "$TAG is not the pending snapshot (pending: ${pending_tag:-none}); ${POINTER_DIR}latest.json does not move"
  finish "$ok"
fi

missing="$(python3 "$HERE/snapshot.py" state --pending "$WORK_DIR/before/pending.json" \
  --result "$RESULT_FILE" --scope "$SCOPE" --run "$RUN_URL" --out "$WORK_DIR/pending.json")" \
  || { log "could not fold this run into pending.json"; exit 1; }

record() {
  "$HERE/commit-to-main.sh" "${POINTER_DIR}pending.json: $TAG, $1" \
    python3 "$HERE/snapshot.py" record --pointer "$WORK_DIR/pending.json" --pointer-dir "$POINTER_DIR"
}

if [ "$missing" = "none" ]; then
  log "no world run has finished into $TAG yet; it stays pending"
  echo "\`$TAG\` stays pending: no world run has finished into it yet. latest.json unchanged." >> "$SUMMARY"
  finish 1
fi
if [ "$missing" != "0" ]; then
  record "$missing region(s) without gazetteers" || log "WARNING could not record the state"
  log "$TAG stays pending: $missing region(s) still missing (listed in pending.json)"
  echo "\`$TAG\` stays pending: $missing region(s) still missing (see \`gazetteer.missingRegions\` in pending.json). latest.json unchanged." >> "$SUMMARY"
  finish 1
fi

log "every region is in; checking $TAG against its releases and the live snapshot"
live=()
[ -f "$WORK_DIR/before/latest.json" ] && live=( --live "$WORK_DIR/before/latest.json" )
python3 "$HERE/snapshot.py" check --pending "$WORK_DIR/pending.json" "${live[@]}" \
  --repo "$GH_REPO" > "$WORK_DIR/check.txt"
check_rc=$?
cat "$WORK_DIR/check.txt"
{
  echo "### Snapshot check"
  echo
  echo '```'
  cat "$WORK_DIR/check.txt"
  echo '```'
} >> "$SUMMARY"
if [ "$check_rc" != "0" ]; then
  record "gazetteers in, tile check failed" || log "WARNING could not record the state"
  log "$TAG stays pending; latest.json unchanged"
  finish 1
fi

"$HERE/commit-to-main.sh" "${POINTER_DIR}latest.json: $TAG" \
  python3 "$HERE/snapshot.py" promote --pointer "$WORK_DIR/pending.json" --pointer-dir "$POINTER_DIR" \
  || { log "could not promote $TAG"; finish 1; }
log "${POINTER_DIR}latest.json -> $TAG"
echo "**${POINTER_DIR}latest.json now points at \`$TAG\`.**" >> "$SUMMARY"
if [ "$ok" != "0" ]; then
  log "FAILED on purpose: $n_quarantined tile(s) were quarantined (gazetteer.carriedOver / .quarantined in ${POINTER_DIR}latest.json)"
  echo "The run is marked failed: $n_quarantined tile(s) were quarantined and hold last month's search or none (see the publish step's summary)." >> "$SUMMARY"
fi
finish "$ok"
