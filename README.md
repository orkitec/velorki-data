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

**A format change never moves `latest.json` by itself.** The manifest's
`formatVersion` is read from the `lookups.dat` next to the tiles on brouter.de.
When it differs from the one in `latest.json`, the snapshot is still published
under its tag, but the run writes `next.json` instead of moving `latest.json`:
riders stay on the last snapshot their app can read, and the next app release is
built and tested against `next.json`. Once that app is in the stores, run the
workflow by hand with `allow_format_change` ticked; `latest.json` moves and
`next.json` can be deleted.

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
  "gazetteer": { "bytes": 262144, "sha256": "…", "updatedAt": "2026-09-16T01:00:00Z" } }
```

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
   file and why only one PBF is ever held at a time. A region that fails is
   reported, not fatal.
3. **publish** downloads every group's artifact, merges them (Geofabrik extracts
   overlap, and a tile is normally cut by several of them, so `merge.py` dedupes
   by OSM id and rebuilds the index), validates the result, then walks the
   snapshot's shards: each `.gaz` goes to the shard whose `manifest.json` lists
   its tile, and that manifest gets its `gazetteer` objects refreshed. A merged
   tile with no `.rd5` anywhere in the snapshot is counted in the step summary
   and not uploaded.

It runs on `workflow_run` when `publish-tiles` finishes successfully, so the
monthly snapshot on the 1st is followed by its gazetteers without a second
schedule to keep in sync. Uploads are idempotent: an asset already on the
release at the same size is left alone, and a re-run into the same tag only
fills the gaps.

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
* **tag** — the snapshot to publish into. Empty means whatever `latest.json`
  points at.

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
* **keep_releases** — snapshots to keep (default 2); older ones are deleted when
  the run finishes.

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
the monthly run pushing `latest.json` counts as activity, so the schedule keeps
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
