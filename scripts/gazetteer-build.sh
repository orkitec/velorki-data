#!/usr/bin/env bash
#
# Build the gazetteer files for one group of Geofabrik extracts.
#
# Called by .github/workflows/publish-gazetteer.yml, one invocation per matrix
# job; runnable locally:
#
#   REGIONS='europe/liechtenstein europe/portugal' \
#   GAZETTEER_DIR=../velorki/tools/gazetteer OUT_DIR=out scripts/gazetteer-build.sh
#
# Why it looks like this
# ----------------------
#   * One PBF on disk at a time. A runner has ~14 GB of free disk and the
#     largest leaf extract is a few GB, so the PBF and build.py's node cache are
#     deleted before the next region starts. `df -h` after every region makes a
#     disk-exhaustion failure obvious in the log instead of a mystery SIGKILL.
#   * A failed region does not fail the group. Geofabrik has bad minutes, and
#     losing 40 good regions because the 41st 404'd would be expensive; the
#     region is reported at the end and the publish job lists it in the summary.
#   * Politeness. Strictly sequential downloads, retries backed off by 30 s, and
#     a User-Agent naming this repository.
set -uo pipefail

REGIONS="${REGIONS:?REGIONS must be set, e.g. 'europe/liechtenstein europe/portugal'}"
# Checkout of orkitec/velorki's tools/gazetteer (build.py lives here).
GAZETTEER_DIR="${GAZETTEER_DIR:?GAZETTEER_DIR must point at tools/gazetteer}"
OUT_DIR="${OUT_DIR:-out}"
WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/gaz-build}"
GEOFABRIK_URL="${GEOFABRIK_URL:-https://download.geofabrik.de}"
USER_AGENT="${USER_AGENT:-velorki-data-gazetteer/1.0 (+https://github.com/orkitec/velorki-data; offline search index builder)}"

log() { printf '%s [gaz-build] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

mkdir -p "$OUT_DIR" "$WORK_DIR" || exit 1

# out/europe__liechtenstein/ - one directory per region, flat, because an
# artifact is unzipped into parts/ next to every other group's and merge.py
# walks the lot. Slashes would nest groups into each other's trees.
slug() { printf '%s' "${1//\//__}"; }

n_ok=0
n_fail=0
failed=""

for region in $REGIONS; do
  pbf="$WORK_DIR/$(slug "$region").osm.pbf"
  dest="$OUT_DIR/$(slug "$region")"
  url="$GEOFABRIK_URL/$region-latest.osm.pbf"

  log "$region: downloading $url"
  if ! curl -fsSL --retry 3 --retry-delay 30 --retry-connrefused --max-time 3600 \
         -A "$USER_AGENT" -o "$pbf" "$url" </dev/null; then
    log "$region: FAIL download"
    rm -f "$pbf"
    n_fail=$(( n_fail + 1 )); failed="$failed $region"
    continue
  fi
  # Geofabrik answers a missing extract with a redirect to its front page, and
  # curl -f is happy with that 200. A PBF starts with a BlobHeader naming
  # "OSMHeader"; an HTML page does not.
  if ! head -c 64 "$pbf" | grep -q OSMHeader; then
    log "$region: FAIL download (not a PBF: $(stat -c%s "$pbf" 2>/dev/null || echo '?') bytes, $(file -b "$pbf" | cut -c1-40))"
    rm -f "$pbf"
    n_fail=$(( n_fail + 1 )); failed="$failed $region"
    continue
  fi
  log "$region: $(stat -c%s "$pbf" 2>/dev/null || echo '?') bytes, building"

  mkdir -p "$dest"
  # TMPDIR is pinned into WORK_DIR so build.py's on-disk node cache (used above
  # 150 MB of PBF) lands where the cleanup below can reach it.
  if TMPDIR="$WORK_DIR" python3 "$GAZETTEER_DIR/build.py" "$pbf" \
       --out "$dest" </dev/null; then
    n_ok=$(( n_ok + 1 ))
    log "$region: ok, $(ls -1 "$dest" | wc -l) tile file(s)"
  else
    log "$region: FAIL build"
    rm -rf "$dest"
    n_fail=$(( n_fail + 1 )); failed="$failed $region"
  fi

  # The PBF and any node cache go before the next region is fetched.
  rm -f "$pbf"
  find "$WORK_DIR" -maxdepth 1 -type f ! -name '*.osm.pbf' -delete 2>/dev/null || true
  df -h "$WORK_DIR" | tail -1
done

log "group done: $n_ok region(s) built, $n_fail failed"
if [ "$n_fail" != "0" ]; then
  log "failed:$failed"
  # Recorded for the job summary; the group itself still uploads what it built.
  printf '%s\n' $failed > "$OUT_DIR/FAILED.txt"
fi
[ "$n_ok" != "0" ] || exit 1
exit 0
