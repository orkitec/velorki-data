# velorki-data

BRouter routing tiles for [Velorki](https://github.com/orkitec), mirrored from
[brouter.de](https://brouter.de/brouter/segments4/) and published as GitHub
Releases.

The Velorki app needs BRouter `.rd5` segment files (5°×5° tiles, one file each,
1–250 MB, ~1,142 files and ~10 GB for the planet). This repository exists so the
app never downloads them from brouter.de directly: brouter.de is a volunteer-run
server that rebuilds the planet nightly, and pointing an app's whole user base at
it would be rude at best. A scheduled workflow copies a snapshot here once a
month and serves it from GitHub's release CDN, which has no documented bandwidth
or total-size limit.

## Base URL

Point `VELORKI_SEGMENTS_URL` at a release's download prefix:

```
https://github.com/orkitec/velorki-data/releases/download/<tag>/
```

The app then fetches `${VELORKI_SEGMENTS_URL}/manifest.json` and
`${VELORKI_SEGMENTS_URL}/<TILE>.rd5`, e.g. `.../E5_N45.rd5`. Both are plain
release assets; GitHub answers them with a 302 to `release-assets.githubusercontent.com`,
which supports `Range` requests, so the app's resumable downloads work unchanged.

The current tag is in [`latest.json`](latest.json) on `main`, readable without
the API at

```
https://raw.githubusercontent.com/orkitec/velorki-data/main/latest.json
```

**The app follows `latest.json`.** `VELORKI_SEGMENTS_URL` in the app is the
raw URL above; the app reads the pointer and fetches the `manifest.json` of
every shard in its `shards` array, merged into one manifest. A monthly run
therefore reaches riders without an app release. A build can still be pinned to a tag's base URL instead; every
tag a shipped build points at goes into `keep-tags.txt`, which prune never
touches.

**`latest.json` only ever names a complete snapshot.** `publish-tiles` writes
a new snapshot to `pending.json` (same shape); `publish-gazetteer` then builds
its gazetteers and, once every region is in and the tiles check out, moves it
to `latest.json` in one commit and deletes `pending.json`. Until then apps keep
the previous snapshot, rd5 and `.gaz` alike. See
[When latest.json moves](#when-latestjson-moves).

**A format change never moves `latest.json` by itself.** The manifest's
`formatVersion` is read from the `lookups.dat` next to the tiles on brouter.de.
When it differs from the one in `latest.json`, the snapshot is still published
under its tag, but the run writes `next.json` instead of `pending.json`:
riders stay on the last snapshot their app can read, and the next app release is
built and tested against `next.json` (dispatch `publish-gazetteer` with its tag
to give it gazetteers; that never moves `latest.json`). Once that app is in the
stores, run the workflow by hand with `allow_format_change` ticked: the snapshot
goes to `pending.json`, and when `latest.json` takes it, `next.json` is deleted.

## Layout of a snapshot

| Asset | What it is |
| --- | --- |
| `manifest.json` | What the app parses: every tile on *this release* with size, mtime and SHA-256 |
| `<TILE>.rd5` | One BRouter segment file, e.g. `E5_N45.rd5` |
| `<TILE>.gaz` | The offline-search index for that tile, when there is one - see [Offline search files](#offline-search-files) |
| `manifest.tsv` | Internal resume checkpoint for the workflow; not used by the app |

`manifest.json` is the shape `brouter/updater/sync.sh` writes and
`SegmentsManifest.parse` reads:

```json
{
  "formatVersion": "11.2",
  "brouterVersion": "v1.7.10",
  "source": "https://brouter.de/brouter/segments4/",
  "generatedAt": "2026-09-13T12:00:00Z",
  "tag": "tiles-20260913",
  "baseUrl": "https://github.com/orkitec/velorki-data/releases/download/tiles-20260913/",
  "shard": 1, "shardCount": 3,
  "tiles": [
    { "tile": "E5_N45", "bytes": 252246016, "updatedAt": "2026-09-13T00:03:00Z", "sha256": "…" }
  ],
  "tileCount": 480,
  "totalBytes": 9987654321
}
```

Each row also carries `contentSha256`: the sha256 of the rd5 with the 8-byte
creation time in its footer zeroed (`scripts/snapshot.py rd5-digest`). `sha256`
and `updatedAt` change with every monthly rebuild; `contentSha256` only when the
tile does, so the app compares it and riders re-download only changed tiles. A
row resumed from an older `manifest.tsv` has none, and the field is then absent.

Unlike the self-hosted updater, this mirror always publishes `sha256`: the tiles
cross two networks and an object store on the way here, and a hash per tile is
cheap when it is computed once a month rather than on every sync pass.

## Offline search files

Next to each `<TILE>.rd5` a snapshot may carry a `<TILE>.gaz`: a small SQLite
file holding the places, points of interest, street names and house-number
anchors inside that tile,
with an FTS5 index over their names. It is what makes the app's search box work
with no network. The builder and the file format live in the app repository at
[`tools/gazetteer`](https://github.com/orkitec/velorki/tree/main/tools/gazetteer);
a file is a few hundred kB to a couple of MB against a 1-250 MB `.rd5`.

The tiles are the same 5 x 5 degree grid as the segments, so the app asks for
`<baseUrl>/<TILE>.gaz` with the tile name it already has. It only does so when
that tile's entry in `manifest.json` carries a `gazetteer` object:

```json
{ "tile": "W20_N30", "bytes": 1527283, "updatedAt": "...", "sha256": "...",
  "gazetteer": { "bytes": 262144, "sha256": "…", "contentSha256": "…", "updatedAt": "2026-09-16T01:00:00Z" } }
```

`contentSha256` is the digest of the file's rows without `meta.built_at`
(`tools/gazetteer/digest.py`); absent when the builder checkout predates it.

No `gazetteer` object means this mirror has no search index for that tile, and
the app falls back to online search. The object's `sha256` is mandatory: the
files are small enough to hash on every run.

### Where they come from

Unlike the `.rd5` files there is no upstream to mirror, so `publish-gazetteer`
builds them from OpenStreetMap:

1. **plan** reads Geofabrik's [`index-v1.json`](https://download.geofabrik.de/index-v1.json),
   takes the *leaf* extracts in the chosen scope (the smallest extracts that
   still tile the area, minus Geofabrik's combination extracts like `europe/dach`
   whose content is already covered), sizes each with a HEAD, and balances them
   into at most 24 groups of equal byte totals.
2. **build** runs one matrix job per group: download one extract, `build.py` it
   into `out/<region>/`, delete the extract, next. A runner has ~14 GB of free
   disk and 16 GB of RAM, which is why the planet is never one pass over one
   file and why only one PBF is ever held at a time. A region that fails does
   not stop its group; the publish step reports it and fails the run.
3. **publish** downloads every group's artifact, merges them (Geofabrik extracts
   overlap, and a tile is normally cut by several of them, so `merge.py` dedupes
   by OSM id and rebuilds the index) one tile at a time, checking each tile's
   inputs and result and quarantining a tile that fails (see
   [When a tile is quarantined](#when-a-tile-is-quarantined)), then walks the
   snapshot's shards: each `.gaz` goes to the shard whose `manifest.json` lists
   its tile, and that manifest gets its `gazetteer` objects refreshed. A merged
   tile with no `.rd5` anywhere in the snapshot is counted in the step summary
   and not uploaded.

It runs on `workflow_run` when `publish-tiles` finishes successfully, so the
monthly snapshot on the 1st is followed by its gazetteers without a second
schedule to keep in sync. It publishes into the snapshot in `pending.json`,
and only if that run of `publish-tiles` wrote it (a by-hand run falls back to
`latest.json`), and its last step decides whether that snapshot goes live -
see below. Uploads are idempotent: an asset already on the
release with the same sha256 is left alone. Every file's `built_at` is the
snapshot's date (`SOURCE_DATE_EPOCH`), so rebuilding unchanged extracts gives
the same bytes. After each shard's manifest is uploaded it is read back and
held to the assets: a size or sha256 that differs fails the run.

A run with failed regions (or a build group lost whole) ends **failed** after
publishing what it built, and its step summary lists them; so does
`gazetteer.missingRegions` in `pending.json`. Fill the gap by dispatching the
workflow with scope `custom` and those region ids: a custom run merges each
tile it touches with the `.gaz` already on the release (`MERGE_PUBLISHED=1`),
so the rebuilt extract's rows join the tile instead of replacing it, and
strikes them off the list. A world run does not merge with the published files;
it rebuilds every tile from scratch and starts the list afresh.

### When latest.json moves

`scripts/promote-snapshot.sh`, the last step of `publish-gazetteer`, when the
run published into the snapshot in `pending.json`:

1. A world run records the regions it missed in `pending.json`
   (`gazetteer.missingRegions`); a custom run strikes the ones it built.
   `europe` and `north-america` runs count for nothing here. Until a world run
   has finished, the snapshot stays pending.
2. With no region missing, `scripts/snapshot.py check` reads every shard of
   the snapshot: each rd5 and `.gaz` in a manifest must be on the release with
   its size and sha256, and no tile may lose its rd5 or its `.gaz` against the
   live snapshot. Tiles that have no `.gaz` here or there (sea, ice, land no
   extract covers) are listed in the summary and are fine.
3. Then `latest.json` becomes `pending.json` (minus the `gazetteer` state but
   for `carriedOver` / `quarantined`, below), `pending.json` is deleted, and
   `next.json` too if it was in the same format.

Quarantined tiles do not hold a snapshot back: each one either carries last
month's `.gaz` or had none last month either, so every tile has the data it
had, and step 2 passes. The run still fails, after the move.

Anything short of that fails the run and leaves `latest.json` alone; fix the
cause and re-run (a custom run for missing regions, a world run otherwise). A
tile that has really lost its data blocks the check every time: to promote
anyway, commit `pending.json` as `latest.json` without its `gazetteer` key and
delete `pending.json`. Commits go through `scripts/commit-to-main.sh`, which
edits a fresh checkout of main and starts over if the push is rejected.

**Pruning** happens right after, in the same step, and only there: it keeps the
snapshots named by `latest.json`, `pending.json`, `next.json` and
`keep-tags.txt`, every snapshot published after the live one (an upload in
progress), and the newest `KEEP_RELEASES` (2, set in the workflow) up to the
live one, so the snapshot riders had before the last move stays a month. It
refuses to run if the live snapshot has no release.

### When a tile is quarantined

One bad tile must not stop the planet. `merge.py` merges tile by tile and
checks each tile's inputs and its output with `check.py`; a tile that fails
(or whose merge raises) is **quarantined**: left out, with the reason, and the
other tiles go on (exit 3, the list in `quarantine.json`). Only a failure of
the whole merge stops the run before publishing: no parts, every tile
quarantined, a full disk, no memory. `publish-gazetteer.sh` then gives each
quarantined tile a `.gaz` all the same (`scripts/snapshot.py carry`):

| Outcome | When | What riders get |
| --- | --- | --- |
| `carried` | the live snapshot (`latest.json`) has a `.gaz` for the tile | last month's file: downloaded from its shard, held to its manifest's size and sha256, opened as a schema 1 file of that tile and run through `check.py` (a file that only fails today's stricter checks is carried anyway: it is the file riders have now), uploaded under the same name and listed in the manifest like any other |
| `kept` | a `custom` run, and the release already has a `.gaz` for the tile; or nothing to carry but an earlier run's file is there | that file, untouched |
| `none` | no `.gaz` for the tile here or in the live snapshot | none, as for a sea tile; the app searches online there, as it did |
| `failed` | the live snapshot has one, but it could not be carried (download, size, sha256, schema) | the snapshot is **not promoted**: the check finds a tile that lost its `.gaz`, and riders stay on the live snapshot with everything |

Each quarantined tile gets an `::error::` annotation and a row in the step
summary (tile, reason, outcome), the run is marked **failed** (so it emails),
and the tiles are recorded in the pointer: `gazetteer.carriedOver` (`{tile:
reason (from tag)}`) and `gazetteer.quarantined` (`{tile: "kept|none|failed:
reason"}`), kept in `latest.json` once the snapshot is promoted. A carried
file was built by last month's builder: the same `schema_version` 1, which is
all an app checks before opening a file (and an app skips a file it cannot
read). Fix the builder (in the app repository), then re-run with scope
`world` to refresh the tile; a `custom` run would merge into the carried file
and keep last month's rows.

### Rehearsal

The whole flow - tiles, `pending`, gazetteers, check, promote, prune - can run
on real Actions for a few tiles without touching anything apps read. Both
workflows take a `rehearsal` input: tags are `rehearsal-<YYYYMMDD>` (never
`tiles-`, never GitHub's "Latest" release), the pointers are
`rehearsal/pending.json` and `rehearsal/latest.json` on `main` (apps read only
the top-level `latest.json`), and pruning deletes only `rehearsal-*` releases.
The real runs never read `rehearsal/` and never prune `rehearsal-*`; scripts
refuse a `tiles-` tag in a rehearsal and a `rehearsal-` tag in a real run, and
a rehearsal of the planet. `publish-gazetteer` learns that a `publish-tiles`
run was a rehearsal from its run title (`publish-tiles [rehearsal]`), and
before building checks that the pending pointer was written by that run. A
rehearsal has its own concurrency group, so it never displaces a queued real
run. It builds `REHEARSAL_REGIONS` (`europe/faroe-islands europe/malta`, set
in `publish-gazetteer.yml`), which lie in the tiles `W10_N60` and `E10_N35`.

Both repositories' changes must be on `main` first: `publish-gazetteer`
checks out `tools/gazetteer` from the app repository's `main`, and only its
`merge.py` quarantines.

1. **A clean run.** Actions → `publish-tiles` → Run workflow on `main`:
   filter `W10_N60 E10_N35`, tag empty, **rehearsal** ticked, break_tile
   empty. Check:
   * the run is titled `publish-tiles [rehearsal]`; a release
     `rehearsal-<today>` with two `.rd5` and `manifest.json`, not marked
     Latest; a commit `rehearsal/pending.json: rehearsal-<today> ...` on `main`;
   * `publish-gazetteer` starts by itself; its plan summary says
     **Rehearsal into `rehearsal-<today>`** with 2 extracts;
   * it ends green; the release has `W10_N60.gaz` and `E10_N35.gaz`, and
     ```sh
     gh release download rehearsal-<today> -R orkitec/velorki-data -p manifest.json -O - \
       | jq '.tiles[] | {tile, gazetteer}'
     ```
     shows a `gazetteer` object for both; a commit
     `rehearsal/latest.json: rehearsal-<today>` and no `rehearsal/pending.json`;
   * nothing real moved: `git log --oneline -3 -- latest.json pending.json`
     shows no new commit, and
     `https://raw.githubusercontent.com/orkitec/velorki-data/main/latest.json`
     still names the same `tiles-` tag.
2. **A quarantined tile.** `publish-tiles` again: the same filter, tag
   `rehearsal-<today>-b`, **rehearsal** ticked, break_tile `W10_N60` (noted in
   `rehearsal/pending.json`; the gazetteer run breaks that tile's parts before
   the merge). Check:
   * `publish-gazetteer` ends **red**, with an annotation *Gazetteer tile
     W10_N60 quarantined ... carried over last month's .gaz from
     rehearsal-<today>* and the table in the publish step's summary;
   * it was promoted all the same: `rehearsal/latest.json` names
     `rehearsal-<today>-b` and holds `gazetteer.carriedOver.W10_N60`;
   * the `W10_N60` gazetteer `sha256` in the `-b` manifest equals the one in
     the first manifest, and `E10_N35`'s was rebuilt.
3. **Pruning** (optional). Two more rehearsals (`-c`, `-d`): after the last,
   the oldest `rehearsal-*` releases are gone, the newest two up to the one in
   `rehearsal/latest.json` stay, and `gh release list -R orkitec/velorki-data`
   shows every `tiles-*` release untouched.

**Clean up** when done:

```sh
gh release list -R orkitec/velorki-data --limit 200 --json tagName \
  --jq '.[].tagName | select(startswith("rehearsal-"))' \
  | while read -r tag; do gh release delete "$tag" -R orkitec/velorki-data --yes --cleanup-tag; done
git pull && git rm -r rehearsal && git commit -m "Remove the rehearsal pointers" && git push
```

### The asset budget

A `.gaz` is a release asset like an `.rd5`, so a shard that carries both holds
twice as many. GitHub's cap is **1000 assets per release**, which is why
`publish-tiles.sh` fills a shard with at most 480 tiles (480 rd5 + 480 gaz +
`manifest.json` + `manifest.tsv`): the planet is three shards instead of two.

### Running it by hand

`Actions → publish-gazetteer → Run workflow`:

* **scope** — `world` (~79 GB of PBF across 512 extracts), `europe` (~31 GB,
  219), `north-america` (~18 GB, 76), or `custom`.
* **regions** — for `custom`, space-separated Geofabrik region ids as they read
  in a download URL, e.g. `europe/liechtenstein europe/portugal`. They are taken
  literally, so a non-leaf id like `europe/germany` builds that one extract.
* **tag** — the snapshot to publish into. Empty means `pending.json`'s, else
  `latest.json`'s. Only the pending snapshot is ever promoted.
* **rehearsal**, **break_tile** — see [Rehearsal](#rehearsal); scope is
  ignored then.

The plan is inspectable without Actions:

```sh
python3 scripts/gazetteer-plan.py --scope europe --dry-run
python3 scripts/gazetteer-plan.py --scope custom --regions "europe/portugal" --dry-run
```

## Sharding, and why the planet is not one release

GitHub allows **at most 1000 assets per release**
([docs](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases#storage-and-bandwidth-quotas)).
The planet is currently **1,142** tiles and a tile costs two assets (`.rd5` +
`.gaz`), so one snapshot does not fit in one release.

A snapshot is therefore split into shards of at most `SHARD_TILES` (480) tiles,
each its own release — three for the planet:

| Shard | Tag | Base URL |
| --- | --- | --- |
| 1 | `tiles-YYYYMMDD` | `…/releases/download/tiles-YYYYMMDD/` |
| 2 | `tiles-YYYYMMDD-s2` | `…/releases/download/tiles-YYYYMMDD-s2/` |
| 3 | `tiles-YYYYMMDD-s3` | `…/releases/download/tiles-YYYYMMDD-s3/` |

Shards fill sequentially over the alphabetically sorted tile list, so a tile
keeps its shard as the upstream list grows, and each shard's `manifest.json`
lists exactly the tiles attached to that shard. `latest.json` names every shard
with its base URL and tile count in `shards`, and the app fetches all of them
and merges the manifests, so **one `VELORKI_SEGMENTS_URL` covers the planet** as
long as it points at the pointer. A build pinned to a shard's base URL sees only
that shard, which is enough for a regional build: run the workflow with a
`filter` covering the area you ship (all of Europe is 224 tiles) and everything
lands in shard 1. `SHARD_TILES` only goes up if GitHub raises the 1000-asset
cap; 480 leaves room for `manifest.json`, `manifest.tsv` and upstream growth.

## Running it

`Actions → publish-tiles → Run workflow`:

* **filter** — space-separated globs against tile names, e.g. `E5_N4*` or
  `W20_N30 W25_N60 W75_N40`. `*` (the default) is the planet.
* **tag** — defaults to `tiles-<YYYYMMDD>`. Re-running with an existing tag
  resumes into it.
* **rehearsal**, **break_tile** — see [Rehearsal](#rehearsal).

It also runs on its own at 03:00 UTC on the 1st of each month.

The script processes tiles in batches — download a batch, hash it, upload it with
`gh release upload --clobber`, delete the local files — so peak disk use is one
batch (`BATCH_BYTES`, 2 GB) rather than the full 10 GB. Downloads from brouter.de
are sequential, with a delay between files and a User-Agent naming this
repository.

### What a run costs

Measured on the three-tile smoke run (`W20_N30 W25_N60 W75_N40`, 117.8 MB):
**25 s** for the whole job, 19 s of it in the script — ~12 MB/s down from
brouter.de, ~25 MB/s up to the release, and roughly 1–1.5 s of connection
overhead per tile on top of the 1 s politeness delay.

Extrapolated to the planet (1,142 tiles, 10 GB), per-tile overhead dominates the
byte transfer, giving **roughly 1.5–2.5 hours**. That fits the 6-hour job cap
with room to spare, but a slow day upstream could eat the margin — which is what
the resume path below is for.

### If a run is cut off

A job is capped at **6 hours** regardless of `timeout-minutes`
([docs](https://docs.github.com/en/actions/reference/limits)).
If a planet run is killed at the cap, re-run the workflow **with the same tag**:
a tile whose asset is already on the release at the right size is skipped, and
the manifest rows gathered so far are checkpointed onto the release as
`manifest.tsv`, so nothing is re-downloaded or re-hashed.

### Bumping `formatVersion`

`formatVersion` is the rd5 lookup version pair from BRouter's
`misc/profiles2/lookups.dat` (`---lookupversion:11` + `---minorversion:2` →
`11.2`). BRouter refuses to read a segment whose header version differs from the
`lookups.dat` it was started with, so this pair *is* the format version the app
and the tiles have to agree on.

To bump it: read the two values from the `lookups.dat` of the BRouter release
brouter.de currently builds `segments4` with, set `RD5_FORMAT_VERSION` (and
`BROUTER_VERSION`) at the top of `scripts/publish-tiles.sh`, and publish under a
**fresh tag**. Never re-run an existing tag across a format change — clients
cache per tile, and a release holding two formats would hand them segments their
`lookups.dat` rejects.

## Limits this design relies on

| Limit | Value | Source |
| --- | --- | --- |
| Assets per release | 1000 | [About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases#storage-and-bandwidth-quotas) |
| Size per asset | < 2 GiB | same (largest tile today is ~252 MB) |
| Total release size / bandwidth | none documented | same — *"There is no limit on the total size of a release, nor bandwidth usage."* |
| Job execution time | 6 h hard cap | [Actions limits](https://docs.github.com/en/actions/reference/limits) |
| Workflow run time | 35 days | [Actions limits](https://docs.github.com/en/actions/reference/limits) |
| Runner disk | 14 GB SSD documented; ~87 GB free measured | [Runner images](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#standard-github-hosted-runners-for-public-repositories) |

Scheduled workflows are disabled automatically after 60 days of repository
inactivity ([docs](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)) —
the monthly run pushing `pending.json` counts as activity, so the schedule keeps
itself alive.

## Licence and attribution

Two different things live in this repository:

* **The workflow and scripts** (`.github/`, `scripts/`) are MIT — see
  [LICENSE](LICENSE).
* **The routing tiles** (`.rd5` release assets) and the **search indexes**
  (`.gaz`, built from Geofabrik's OpenStreetMap extracts) are **not** ours. They
  are derived from OpenStreetMap data and are therefore licensed under the
  [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/):

  > © OpenStreetMap contributors, ODbL 1.0.

  They are produced by [BRouter](https://github.com/abrensch/brouter) and
  mirrored from <https://brouter.de/brouter/segments4/>, which is the upstream
  and the authoritative source. This repository adds nothing to them — it only
  copies them, hashes them and re-publishes them so app traffic does not land on
  brouter.de.

Anything that displays or routes on this data must carry the OpenStreetMap
attribution.
