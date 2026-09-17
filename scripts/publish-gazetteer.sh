#!/usr/bin/env bash
#
# Merge the per-group gazetteer parts and publish one `<TILE>.gaz` next to every
# `<TILE>.rd5` of a snapshot.
#
# Called by .github/workflows/publish-gazetteer.yml; runnable locally with `gh`
# authenticated:
#
#   GH_REPO=orkitec/velorki-data GAZETTEER_DIR=../velorki/tools/gazetteer \
#   PARTS_DIR=parts scripts/publish-gazetteer.sh
#
# Why it looks like this
# ----------------------
#   * Merge first, publish second. Geofabrik extracts overlap at their edges and
#     a 5x5 degree tile is usually cut by several of them, so a tile file only
#     becomes complete once every part that touches it has been folded in
#     (merge.py dedupes by OSM id and renumbers the one id space).
#   * The rd5 tiles decide which gazetteers exist. A snapshot is sharded across
#     several releases and each shard's manifest.json lists only its own tiles,
#     so a .gaz goes to the shard whose manifest names its tile - never to the
#     tag alone. A merged tile with no rd5 anywhere is land BRouter does not
#     route and is reported, not uploaded.
#   * Idempotent and resumable. An asset already on the release at the same size
#     is left alone (these files are rebuilt from scratch every run and a size
#     match on a few-MB SQLite file is a strong signal), but manifest.py always
#     re-runs: it is cheap, and it is what makes the manifest match the assets.
#   * A gap-filling run merges with what is published. With MERGE_PUBLISHED=1
#     (the workflow sets it for scope `custom`) the .gaz already on the release
#     is one more input to the merge for every tile the new parts touch, so
#     rebuilding one failed extract adds its rows to the tile instead of
#     replacing the whole tile with that extract's slice of it. A world run
#     leaves it off: it rebuilds every tile from scratch, which is also how
#     objects deleted in OSM leave the files.
#   * A failed region fails the run - after publishing. What was built is still
#     better published than withheld, but a green run with a hole in it is how
#     fifteen missing extracts went unnoticed once; the exit code and the step
#     summary name the regions and the re-run that fills them.
set -uo pipefail

: "${GH_REPO:?GH_REPO must be set, e.g. orkitec/velorki-data}"
# Checkout of orkitec/velorki's tools/gazetteer (merge.py, check.py, manifest.py).
: "${GAZETTEER_DIR:?GAZETTEER_DIR must point at tools/gazetteer}"
PARTS_DIR="${PARTS_DIR:-parts}"
MERGED_DIR="${MERGED_DIR:-merged}"
WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/gaz-publish}"
POINTER_FILE="${POINTER_FILE:-latest.json}"
# gh takes many assets per call; a few dozen keeps the command line sane and the
# log readable without paying connection setup per file.
UPLOAD_BATCH="${UPLOAD_BATCH:-40}"
MERGE_PUBLISHED="${MERGE_PUBLISHED:-0}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

log() { printf '%s [gaz-publish] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FATAL $*"; exit 1; }

mkdir -p "$WORK_DIR" || die "could not create $WORK_DIR"

# ------------------------------------------------------------------- merge ---
[ -d "$PARTS_DIR" ] || die "$PARTS_DIR does not exist - no build artifacts?"

# One directory per built region, named by gazetteer-build.sh's slug.
regions_built=$(find "$PARTS_DIR" -mindepth 2 -maxdepth 2 -type d | wc -l)
failed_regions=$(cat "$PARTS_DIR"/*/FAILED.txt 2>/dev/null | tr '\n' ' ')
parts_count=$(find "$PARTS_DIR" -name '*.gaz' | wc -l)
[ "$parts_count" -gt 0 ] || die "no .gaz files under $PARTS_DIR"
log "$parts_count part file(s) from $regions_built region(s)"

# --------------------------------------------------------------------- tag ---
TAG="${TAG:-}"
if [ -z "$TAG" ]; then
  TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "$POINTER_FILE")" \
    || die "could not read the tag from $POINTER_FILE"
fi
log "publishing into snapshot $TAG"

# Shards are $TAG, $TAG-s2, $TAG-s3, ... and stop at the first tag with no
# release, exactly the sequence publish-tiles.sh creates.
shards=()
shard=1
while :; do
  if [ "$shard" = "1" ]; then shard_tag="$TAG"; else shard_tag="$TAG-s$shard"; fi
  gh release view "$shard_tag" --repo "$GH_REPO" >/dev/null 2>&1 || break
  shards+=( "$shard_tag" )
  shard=$(( shard + 1 ))
done
[ "${#shards[@]}" -gt 0 ] || die "no release for tag $TAG"
log "snapshot has ${#shards[@]} shard(s): ${shards[*]}"

# ------------------------------------------------------- published tiles ---
# For a gap-filling run: the .gaz already on the release, for every tile the
# new parts touch, so the merge below folds the new rows into it.
merge_inputs=( "$PARTS_DIR" )
if [ "$MERGE_PUBLISHED" = "1" ]; then
  PUBLISHED_DIR="$WORK_DIR/published"
  rm -rf "$PUBLISHED_DIR"; mkdir -p "$PUBLISHED_DIR"
  find "$PARTS_DIR" -name '*.gaz' -exec basename {} .gaz \; | sort -u > "$WORK_DIR/touched.txt"
  n_published=0
  for shard_tag in "${shards[@]}"; do
    gh release view "$shard_tag" --repo "$GH_REPO" --json assets --jq '.assets[].name' \
      > "$WORK_DIR/$shard_tag.assets" 2>/dev/null || : > "$WORK_DIR/$shard_tag.assets"
    while read -r tile; do
      [ -n "$tile" ] || continue
      grep -qxF "$tile.gaz" "$WORK_DIR/$shard_tag.assets" || continue
      gh release download "$shard_tag" --repo "$GH_REPO" --pattern "$tile.gaz" \
          --dir "$PUBLISHED_DIR" --clobber </dev/null >/dev/null 2>&1 \
        || die "$shard_tag: could not download the published $tile.gaz"
      n_published=$(( n_published + 1 ))
    done < "$WORK_DIR/touched.txt"
  done
  log "merging with $n_published published tile(s) (MERGE_PUBLISHED=1)"
  [ "$n_published" = "0" ] || merge_inputs+=( "$PUBLISHED_DIR" )
fi

rm -rf "$MERGED_DIR"; mkdir -p "$MERGED_DIR"
log "merging into $MERGED_DIR"
python3 "$GAZETTEER_DIR/merge.py" "$MERGED_DIR" "${merge_inputs[@]}" \
  || die "merge.py failed"

shopt -s nullglob
merged_files=( "$MERGED_DIR"/*.gaz )
shopt -u nullglob
[ "${#merged_files[@]}" -gt 0 ] || die "merge.py produced no files"
log "merged ${#merged_files[@]} tile(s); validating"
python3 "$GAZETTEER_DIR/check.py" "${merged_files[@]}" || die "check.py rejected a merged file"

# --------------------------------------------------------------- per shard ---
# Every tile any shard claimed, so the leftovers can be reported at the end.
: > "$WORK_DIR/claimed.txt"
summary_rows=""
total_up=0
total_skip=0

for shard_tag in "${shards[@]}"; do
  dir="$WORK_DIR/$shard_tag"
  rm -rf "$dir"; mkdir -p "$dir"

  gh release download "$shard_tag" --repo "$GH_REPO" --pattern manifest.json \
      --dir "$dir" --clobber </dev/null >/dev/null 2>&1 \
    || { log "$shard_tag: no manifest.json on the release, skipping"; continue; }

  # The shard's manifest as it stands. manifest.py is handed a *filtered* copy
  # below and its result is spliced back into this one, so a europe-scoped run
  # cannot strip the gazetteer objects of the american tiles on the same shard.
  mv "$dir/manifest.json" "$dir/manifest.orig.json"

  # Tiles this shard serves, one per line.
  python3 -c '
import json, sys
manifest = json.load(open(sys.argv[1]))
for entry in manifest.get("tiles", []):
    if entry.get("tile"):
        print(entry["tile"])
' "$dir/manifest.orig.json" > "$dir/tiles.txt" || die "$shard_tag: unreadable manifest.json"

  # Assets already on the release, "name<TAB>size".
  gh release view "$shard_tag" --repo "$GH_REPO" --json assets \
    --jq '.assets[] | "\(.name)\t\(.size)"' > "$dir/assets.tsv" 2>/dev/null || : > "$dir/assets.tsv"

  n_have=0 n_up=0 n_skip=0
  batch=()
  # Local copies live beside the manifest because manifest.py reads the whole
  # directory and drops the gazetteer object of any tile whose file is missing.
  while read -r tile; do
    [ -n "$tile" ] || continue
    src="$MERGED_DIR/$tile.gaz"
    [ -f "$src" ] || continue
    printf '%s\n' "$tile" >> "$WORK_DIR/claimed.txt"
    cp -f "$src" "$dir/$tile.gaz" || die "$shard_tag: could not stage $tile.gaz"
    n_have=$(( n_have + 1 ))

    have_size="$(awk -F'\t' -v n="$tile.gaz" '$1==n {print $2; exit}' "$dir/assets.tsv")"
    if [ -n "$have_size" ] && [ "$have_size" = "$(stat -c%s "$dir/$tile.gaz")" ]; then
      n_skip=$(( n_skip + 1 ))
      continue
    fi
    batch+=( "$dir/$tile.gaz" )
    if [ "${#batch[@]}" -ge "$UPLOAD_BATCH" ]; then
      gh release upload "$shard_tag" --repo "$GH_REPO" --clobber "${batch[@]}" </dev/null \
        || die "$shard_tag: upload failed"
      n_up=$(( n_up + ${#batch[@]} )); batch=()
    fi
  done < "$dir/tiles.txt"

  if [ "${#batch[@]}" -gt 0 ]; then
    gh release upload "$shard_tag" --repo "$GH_REPO" --clobber "${batch[@]}" </dev/null \
      || die "$shard_tag: upload failed"
    n_up=$(( n_up + ${#batch[@]} ))
  fi

  if [ "$n_have" = "0" ]; then
    log "$shard_tag: no merged tile belongs to this shard"
    summary_rows="$summary_rows| \`$shard_tag\` | $(wc -l < "$dir/tiles.txt") | 0 | 0 | 0 |"$'\n'
    continue
  fi

  # manifest.py rewrites the gazetteer object of every tile in the manifest it
  # is given from the files next to it, so it gets a manifest holding only the
  # tiles staged above; the objects it writes are then spliced back onto the
  # real one and every other tile keeps whatever it already had.
  python3 -c '
import json, os, sys
manifest = json.load(open(sys.argv[1]))
directory = sys.argv[2]
manifest["tiles"] = [
    entry for entry in manifest.get("tiles", [])
    if os.path.isfile(os.path.join(directory, "%s.gaz" % entry.get("tile")))
]
json.dump(manifest, open(os.path.join(directory, "manifest.json"), "w"), indent=1)
' "$dir/manifest.orig.json" "$dir" || die "$shard_tag: could not filter manifest.json"

  python3 "$GAZETTEER_DIR/manifest.py" "$dir" --quiet || die "$shard_tag: manifest.py failed"

  python3 -c '
import json, sys
full = json.load(open(sys.argv[1]))
fresh = {
    entry["tile"]: entry["gazetteer"]
    for entry in json.load(open(sys.argv[2])).get("tiles", [])
    if entry.get("gazetteer")
}
for entry in full.get("tiles", []):
    if entry.get("tile") in fresh:
        entry["gazetteer"] = fresh[entry["tile"]]
with open(sys.argv[2], "w") as handle:
    json.dump(full, handle, indent=1)
    handle.write("\n")
' "$dir/manifest.orig.json" "$dir/manifest.json" || die "$shard_tag: could not splice manifest.json"
  gh release upload "$shard_tag" --repo "$GH_REPO" --clobber "$dir/manifest.json" </dev/null \
    || die "$shard_tag: could not upload manifest.json"

  log "$shard_tag: $n_have tile(s) with a gazetteer - $n_up uploaded, $n_skip unchanged"
  summary_rows="$summary_rows| \`$shard_tag\` | $(wc -l < "$dir/tiles.txt") | $n_have | $n_up | $n_skip |"$'\n'
  total_up=$(( total_up + n_up ))
  total_skip=$(( total_skip + n_skip ))
  rm -rf "$dir"
done

# ----------------------------------------------------------------- summary ---
# Tiles the build produced that no shard serves: land outside the rd5 coverage
# of this snapshot (the current snapshot is a three-tile test), or a snapshot
# that is older than the extracts.
sort -u "$WORK_DIR/claimed.txt" > "$WORK_DIR/claimed.sorted"
orphans=""
n_orphan=0
for file in "${merged_files[@]}"; do
  tile="$(basename "$file" .gaz)"
  grep -qxF "$tile" "$WORK_DIR/claimed.sorted" && continue
  orphans="$orphans $tile"
  n_orphan=$(( n_orphan + 1 ))
done

{
  echo "### publish-gazetteer"
  echo
  echo "Snapshot \`$TAG\`, ${#shards[@]} shard(s). $regions_built region(s) built, ${#merged_files[@]} tile(s) merged."
  echo
  echo "| Shard | Tiles on shard | With a gazetteer | Uploaded | Unchanged |"
  echo "| --- | ---: | ---: | ---: | ---: |"
  printf '%s' "$summary_rows"
  echo
  echo "Uploaded $total_up, unchanged $total_skip."
  echo
  if [ "$n_orphan" != "0" ]; then
    echo "**$n_orphan merged tile(s) have no rd5 in this snapshot** and were not uploaded:"
    echo
    echo '```'
    printf '%s\n' $orphans | fmt -w 100
    echo '```'
  else
    echo "Every merged tile had an rd5 to sit next to."
  fi
  echo
  if [ -n "${failed_regions// /}" ]; then
    echo "**Region(s) that failed to build** (the run is marked failed; dispatch the workflow with scope \`custom\` and these regions to fill the gap):"
    echo
    echo '```'
    printf '%s\n' $failed_regions | fmt -w 100
    echo '```'
  else
    echo "No region failed to build."
  fi
} >> "$SUMMARY"

log "done - $total_up uploaded, $total_skip unchanged, $n_orphan tile(s) without an rd5"
if [ -n "${failed_regions// /}" ]; then
  log "FAILED region(s): $failed_regions"
  log "fill the gap: dispatch publish-gazetteer with scope 'custom' and these regions (it merges with the published tiles)"
  exit 1
fi
exit 0
