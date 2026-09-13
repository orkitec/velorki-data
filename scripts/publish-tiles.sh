#!/usr/bin/env bash
#
# Mirror BRouter rd5 segment tiles from brouter.de into GitHub Releases.
#
# Called by .github/workflows/publish-tiles.yml; runnable locally with `gh`
# authenticated:  GH_REPO=orkitec/velorki-data FILTER='E5_N45' scripts/publish-tiles.sh
#
# Why it looks like this
# ----------------------
#   * Disk. The planet is ~10 GB. The docs budget a standard runner at 14 GB of
#     SSD, though a 2026 ubuntu-latest actually reports ~87 GB free, so this is
#     headroom rather than a wall today. Tiles are still processed in batches -
#     download a batch, hash it, upload it, delete it - so peak disk usage is one
#     batch ($BATCH_BYTES) and the job does not depend on which figure is true.
#   * The 1000-asset limit. GitHub allows at most 1000 assets per release and
#     the planet is 1142 tiles, so a snapshot is split into shards of at most
#     $SHARD_TILES tiles, each its own release with its own manifest.json.
#     Shards fill sequentially so a tile keeps its shard as upstream grows.
#   * Resume. The 6-hour job cap may not be enough for a cold planet run, so a
#     tile whose asset is already on the release at the right size is skipped,
#     and the manifest rows accumulated so far are checkpointed onto the release
#     as manifest.tsv - a resumed run does not re-download and re-hash what a
#     previous run already published.
#   * Politeness. brouter.de is a volunteer-run server: one sequential stream, a
#     delay between files, and a User-Agent that says who we are.
set -uo pipefail

SEGMENTS_URL="${SEGMENTS_URL:-https://brouter.de/brouter/segments4/}"
FILTER="${FILTER:-*}"
TAG="${TAG:-tiles-$(date -u +%Y%m%d)}"
WORK_DIR="${WORK_DIR:-$PWD/.tiles}"

# The rd5 on-disk format is identified by the lookup version pair carried in
# BRouter's misc/profiles2/lookups.dat ("---lookupversion:11" /
# "---minorversion:2"). BRouter refuses to read a segment whose header version
# differs from the lookups.dat it was started with, so this pair *is* the format
# version the app and the tiles must agree on.
#
# HOW TO BUMP IT: read the two values out of the lookups.dat of the BRouter
# release brouter.de is currently building segments4 with, set
# RD5_FORMAT_VERSION to "<lookupversion>.<minorversion>", and publish under a
# FRESH tag. Never re-run an existing tag across a version change: clients cache
# per tile, and a release holding two formats would hand them segments their
# lookups.dat rejects. Bump BROUTER_VERSION in the same commit.
RD5_FORMAT_VERSION="${RD5_FORMAT_VERSION:-11.2}"
BROUTER_VERSION="${BROUTER_VERSION:-v1.7.10}"

# At most 1000 assets may be attached to one release. Each shard also carries
# manifest.json and manifest.tsv, so the tile cap leaves room for those and for
# upstream growth.
SHARD_TILES="${SHARD_TILES:-900}"
# Upload (and free) once a batch reaches this many bytes on disk.
BATCH_BYTES="${BATCH_BYTES:-2000000000}"
# Seconds to wait between two downloads from brouter.de.
POLITE_DELAY="${POLITE_DELAY:-1}"
USER_AGENT="${USER_AGENT:-velorki-data-mirror/1.0 (+https://github.com/orkitec/velorki-data; mirror of brouter.de for the Velorki bike app)}"
# Keep this many snapshots; older ones are deleted at the end of a run.
KEEP_RELEASES="${KEEP_RELEASES:-2}"

: "${GH_REPO:?GH_REPO must be set, e.g. orkitec/velorki-data}"
REPO_URL="https://github.com/$GH_REPO"
TAB=$'\t'

log() { printf '%s [publish] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FATAL $*"; exit 1; }

human() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.2f GB", b/1073741824;
    else if (b >= 1048576) printf "%.1f MB", b/1048576;
    else if (b >= 1024) printf "%.1f kB", b/1024;
    else printf "%d B", b;
  }'
}

df_free() { df -B1 --output=avail "$WORK_DIR" | tail -1 | tr -d ' '; }

# ------------------------------------------------------------------ filter ---
# $FILTER is a space-separated list of globs. It must be split on whitespace but
# NOT pathname-expanded: the default is "*" (the planet), and an unguarded
# `for g in $FILTER` would expand that against the working directory.
FILTER_PATS=()
split_filter() {
  set -f
  # shellcheck disable=SC2206  # deliberate word splitting, globbing disabled
  FILTER_PATS=( $FILTER )
  set +f
  [ "${#FILTER_PATS[@]}" -gt 0 ] || die "FILTER is empty; use '*' for the planet"
}

matches_filter() {
  local tile="$1" g
  for g in "${FILTER_PATS[@]}"; do
    # shellcheck disable=SC2254  # $g is intentionally a glob pattern
    case "$tile" in $g) return 0 ;; esac
  done
  return 1
}

# ------------------------------------------------------------------- index ---
# nginx autoindex rows look like:
#   <a href="E5_N45.rd5">E5_N45.rd5</a>   13-Sep-2026 01:03   12159376
# Timestamps are map-snapshot time in CET (brouter.de states this in a marker
# file in the same directory), so they are read as CET and emitted as UTC.
fetch_index() {
  local html="$WORK_DIR/index.html"
  log "fetching index $SEGMENTS_URL"
  curl -fsSL --retry 3 --retry-delay 5 --max-time 120 -A "$USER_AGENT" \
    "$SEGMENTS_URL" -o "$html" || die "could not fetch the segment index"

  sed -nE 's#^<a href="([^"/]+)\.rd5">[^<]*</a>[[:space:]]+([0-9]{2}-[A-Za-z]{3}-[0-9]{4} [0-9]{2}:[0-9]{2})[[:space:]]+([0-9]+).*$#\1\t\3\t\2#p' \
    "$html" | sort > "$WORK_DIR/index.tsv"

  [ -s "$WORK_DIR/index.tsv" ] \
    || die "index contained no .rd5 rows - did the upstream layout change?"
  log "index lists $(wc -l < "$WORK_DIR/index.tsv") tiles"
}

# ------------------------------------------------------------------ shards ---
shard_tag() { if [ "$1" = "1" ]; then printf '%s' "$TAG"; else printf '%s-s%s' "$TAG" "$1"; fi; }
shard_base() { printf '%s/releases/download/%s/' "$REPO_URL" "$(shard_tag "$1")"; }

release_notes() {
  local shard="$1" of="$2"
  cat <<NOTES
BRouter routing tiles (rd5, format version $RD5_FORMAT_VERSION), mirrored from
<$SEGMENTS_URL> on $(date -u +%Y-%m-%d).

Base URL for this shard - this is what \`VELORKI_SEGMENTS_URL\` is set to:

    $(shard_base "$shard")

Shard $shard of $of. GitHub allows at most 1000 assets per release, so a full
planet snapshot is split across several releases; each shard carries its own
\`manifest.json\` listing only the tiles attached to that shard.

Data: (c) OpenStreetMap contributors, ODbL. Produced by BRouter; upstream is
<https://brouter.de/brouter/segments4/>.
NOTES
}

ensure_release() {
  local tag="$1" shard="$2" of="$3" latest="--latest=false"
  [ "$shard" = "1" ] && latest="--latest"
  if gh release view "$tag" --repo "$GH_REPO" >/dev/null 2>&1; then
    log "release $tag already exists, resuming into it"
    return 0
  fi
  log "creating release $tag (shard $shard of $of)"
  gh release create "$tag" --repo "$GH_REPO" --title "$tag (shard $shard/$of)" \
    "$latest" --notes "$(release_notes "$shard" "$of")" \
    || die "could not create release $tag"
}

# Assets already on the release, as "name<TAB>size".
release_assets() {
  gh release view "$1" --repo "$GH_REPO" --json assets \
    --jq '.assets[] | "\(.name)\t\(.size)"' 2>/dev/null || true
}

# ---------------------------------------------------------------- manifest ---
# Rows accumulate in manifest.tsv as "tile<TAB>bytes<TAB>updatedAt<TAB>sha256".
write_manifest() {
  local state="$1" out="$2" shard="$3" of="$4"
  jq -R -s --arg fv "$RD5_FORMAT_VERSION" --arg bv "$BROUTER_VERSION" \
      --arg src "$SEGMENTS_URL" --arg filter "$FILTER" \
      --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg tag "$(shard_tag "$shard")" \
      --arg base "$(shard_base "$shard")" \
      --argjson shard "$shard" --argjson shards "$of" '
    [ split("\n")[] | select(length > 0) | split("\t")
      | { tile: .[0], bytes: (.[1] | tonumber), updatedAt: .[2], sha256: .[3] } ]
    | sort_by(.tile)
    | { formatVersion: $fv, brouterVersion: $bv, source: $src,
        segmentFilter: $filter, generatedAt: $gen,
        tag: $tag, baseUrl: $base, shard: $shard, shardCount: $shards,
        tiles: ., tileCount: length, totalBytes: (map(.bytes) | add // 0) }
  ' < "$state" > "$out" || die "could not build $out"
}

# --------------------------------------------------------------- one shard ---
# flush_batch reads and mutates publish_shard's locals (bash dynamic scoping):
# batch, batch_bytes, tag, state.
flush_batch() {
  [ "${#batch[@]}" -gt 0 ] || return 0
  log "$tag: uploading ${#batch[@]} asset(s), $(human "$batch_bytes")"
  gh release upload "$tag" --repo "$GH_REPO" --clobber "${batch[@]}" </dev/null \
    || die "upload to $tag failed"
  rm -f "${batch[@]}"
  # Checkpoint the manifest rows so an interrupted run can resume cheaply.
  gh release upload "$tag" --repo "$GH_REPO" --clobber "$state" </dev/null >/dev/null \
    || log "$tag: WARNING could not checkpoint manifest.tsv"
  batch=(); batch_bytes=0
  log "$tag: $(human "$(df_free)") free on disk"
}

publish_shard() {
  local shard="$1" of="$2" list="$3"
  local tag; tag="$(shard_tag "$shard")"
  local dir="$WORK_DIR/$tag"
  local state="$dir/manifest.tsv"
  rm -rf "$dir"; mkdir -p "$dir"

  ensure_release "$tag" "$shard" "$of"

  # Recover the manifest rows of a previous, interrupted run.
  : > "$state"
  if gh release download "$tag" --repo "$GH_REPO" --pattern manifest.tsv \
       --dir "$dir" --clobber </dev/null >/dev/null 2>&1 && [ -s "$state" ]; then
    log "$tag: recovered $(wc -l < "$state") manifest row(s) from a previous run"
  fi

  local have; have="$(release_assets "$tag")"

  local batch=() batch_bytes=0
  local n_up=0 n_skip=0 n_fail=0
  local tile bytes idxdate updated dst actual sha have_size resume

  # The tile list is read on fd 3 so that curl/gh cannot swallow it from stdin.
  while IFS="$TAB" read -r tile bytes idxdate <&3; do
    [ -n "$tile" ] || continue
    updated="$(TZ=CET date -u -d "$idxdate" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"

    # Already published at the right size, and its manifest row survived?
    have_size="$(printf '%s\n' "$have" | awk -F'\t' -v n="$tile.rd5" '$1==n {print $2; exit}')"
    if [ "$have_size" = "$bytes" ] && grep -q "^$tile$TAB" "$state"; then
      n_skip=$(( n_skip + 1 ))
      continue
    fi

    dst="$dir/$tile.rd5"
    resume=()
    [ -f "$dst" ] && resume=( -C - )
    if ! curl -fsSL --retry 3 --retry-delay 5 --max-time 3600 "${resume[@]}" \
           -A "$USER_AGENT" -o "$dst" "$SEGMENTS_URL$tile.rd5" </dev/null; then
      rm -f "$dst"; log "$tag: $tile FAIL download"; n_fail=$(( n_fail + 1 )); continue
    fi
    actual="$(stat -c%s "$dst" 2>/dev/null || echo -1)"
    if [ "$actual" != "$bytes" ]; then
      rm -f "$dst"
      log "$tag: $tile FAIL size mismatch (got $actual, index says $bytes)"
      n_fail=$(( n_fail + 1 )); continue
    fi
    sha="$(sha256sum "$dst" | cut -d' ' -f1)"

    # Replace any stale row for this tile, then append the fresh one.
    grep -v "^$tile$TAB" "$state" > "$state.new" 2>/dev/null || : > "$state.new"
    mv "$state.new" "$state"
    printf '%s\t%s\t%s\t%s\n' "$tile" "$actual" "$updated" "$sha" >> "$state"

    batch+=( "$dst" ); batch_bytes=$(( batch_bytes + actual ))
    n_up=$(( n_up + 1 ))
    log "$tag: $tile ok $(human "$actual")"

    [ "$batch_bytes" -ge "$BATCH_BYTES" ] && flush_batch
    sleep "$POLITE_DELAY"
  done 3< "$list"

  flush_batch

  write_manifest "$state" "$dir/manifest.json" "$shard" "$of"
  gh release upload "$tag" --repo "$GH_REPO" --clobber "$dir/manifest.json" </dev/null \
    || die "could not upload manifest.json to $tag"
  log "$tag: done - $n_up uploaded, $n_skip already present, $n_fail failed"
  rm -rf "$dir"
  [ "$n_fail" = "0" ] || return 1
  return 0
}

# ------------------------------------------------------------- latest.json ---
update_latest_pointer() {
  local of="$1" i shards="[]"
  for i in $(seq 1 "$of"); do
    shards="$(jq -c --arg t "$(shard_tag "$i")" --arg b "$(shard_base "$i")" \
      --argjson n "$(wc -l < "$WORK_DIR/shard.$i")" \
      '. + [{tag: $t, baseUrl: $b, tileCount: $n}]' <<<"$shards")"
  done
  jq -n --arg tag "$TAG" --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg fv "$RD5_FORMAT_VERSION" --arg bv "$BROUTER_VERSION" \
        --arg base "$(shard_base 1)" --arg src "$SEGMENTS_URL" \
        --argjson shards "$shards" '
    { tag: $tag, generatedAt: $gen, formatVersion: $fv, brouterVersion: $bv,
      source: $src, baseUrl: $base, shardCount: ($shards | length),
      shards: $shards, tileCount: ($shards | map(.tileCount) | add // 0) }' \
    > latest.json || die "could not write latest.json"
  log "latest.json -> $TAG ($of shard(s))"
}

# ----------------------------------------------------------------- pruning ---
# Keep the $KEEP_RELEASES newest snapshots (all shards of each); delete the rest.
#
# Ordering is by publishedAt, not by gh's default list order: a release's
# createdAt is the *tag's* commit date, so two snapshots cut from the same commit
# tie and could order arbitrarily. $TAG is also prepended unconditionally, so the
# snapshot this run just published can never be the one pruned.
prune_releases() {
  local keep snap t
  keep="$( { printf '%s\n' "$TAG"
             gh release list --repo "$GH_REPO" --limit 200 --json tagName,publishedAt \
               --jq 'sort_by(.publishedAt) | reverse | .[].tagName' \
             | sed -E 's/-s[0-9]+$//'
           } | awk '!seen[$0]++' | head -n "$KEEP_RELEASES")"
  if [ -z "$keep" ]; then
    log "no releases listed, nothing to prune"
    return 0
  fi
  log "keeping snapshot(s): $(echo "$keep" | tr '\n' ' ')"
  while read -r t; do
    [ -n "$t" ] || continue
    snap="$(sed -E 's/-s[0-9]+$//' <<<"$t")"
    grep -qxF "$snap" <<<"$keep" && continue
    log "deleting old release $t"
    gh release delete "$t" --repo "$GH_REPO" --yes --cleanup-tag </dev/null || true
  done < <(gh release list --repo "$GH_REPO" --limit 200 --json tagName --jq '.[].tagName')
}

# -------------------------------------------------------------------- main ---
main() {
  command -v gh >/dev/null || die "gh is not installed"
  command -v jq >/dev/null || die "jq is not installed"
  mkdir -p "$WORK_DIR"
  rm -f "$WORK_DIR"/part.* "$WORK_DIR"/shard.* "$WORK_DIR"/selected.tsv
  split_filter
  fetch_index

  local tile bytes idxdate
  : > "$WORK_DIR/selected.tsv"
  while IFS="$TAB" read -r tile bytes idxdate; do
    matches_filter "$tile" \
      && printf '%s\t%s\t%s\n' "$tile" "$bytes" "$idxdate" >> "$WORK_DIR/selected.tsv"
  done < "$WORK_DIR/index.tsv"

  local n total of=0 i f rc=0
  n="$(wc -l < "$WORK_DIR/selected.tsv")"
  [ "$n" -gt 0 ] || die "FILTER='$FILTER' matched no tile in the index"
  total="$(awk -F'\t' '{s+=$2} END {print s+0}' "$WORK_DIR/selected.tsv")"
  log "$n tile(s) selected, $(human "$total") (filter='$FILTER')"

  # Sequential shard fill: shard 1 takes the first $SHARD_TILES tiles of the
  # sorted list, shard 2 the next, and so on, so a tile keeps its shard as the
  # upstream tile list grows.
  split -l "$SHARD_TILES" -d -a 3 "$WORK_DIR/selected.tsv" "$WORK_DIR/part."
  for f in "$WORK_DIR"/part.*; do of=$(( of + 1 )); mv "$f" "$WORK_DIR/shard.$of"; done
  log "$of shard(s) of at most $SHARD_TILES tiles each"

  for i in $(seq 1 "$of"); do
    publish_shard "$i" "$of" "$WORK_DIR/shard.$i" || rc=1
  done

  update_latest_pointer "$of"
  prune_releases

  log "base URL (shard 1): $(shard_base 1)"
  return "$rc"
}

main "$@"
