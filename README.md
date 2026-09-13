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

**The app does not read `latest.json` yet.** Today `VELORKI_SEGMENTS_URL` is
pinned to a concrete tag at build time, which is the safer arrangement anyway: a
build keeps serving the tiles it was tested against, and moving to a new snapshot
is a deliberate change. `latest.json` is there so a future app version (or a
release script) can discover the newest tag without hardcoding a date.

## Layout of a snapshot

| Asset | What it is |
| --- | --- |
| `manifest.json` | What the app parses: every tile on *this release* with size, mtime and SHA-256 |
| `<TILE>.rd5` | One BRouter segment file, e.g. `E5_N45.rd5` |
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
  "shard": 1, "shardCount": 2,
  "tiles": [
    { "tile": "E5_N45", "bytes": 252246016, "updatedAt": "2026-09-13T00:03:00Z", "sha256": "…" }
  ],
  "tileCount": 900,
  "totalBytes": 9987654321
}
```

Unlike the self-hosted updater, this mirror always publishes `sha256`: the tiles
cross two networks and an object store on the way here, and a hash per tile is
cheap when it is computed once a month rather than on every sync pass.

## Sharding, and why the planet is not one release

GitHub allows **at most 1000 assets per release**
([docs](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases#storage-and-bandwidth-quotas)).
The planet is currently **1,142** tiles, so one snapshot does not fit in one
release.

A snapshot is therefore split into shards of at most 900 tiles, each its own
release:

| Shard | Tag | Base URL |
| --- | --- | --- |
| 1 | `tiles-YYYYMMDD` | `…/releases/download/tiles-YYYYMMDD/` |
| 2 | `tiles-YYYYMMDD-s2` | `…/releases/download/tiles-YYYYMMDD-s2/` |

Shards fill sequentially over the alphabetically sorted tile list, so a tile
keeps its shard as the upstream list grows, and each shard's `manifest.json`
lists exactly the tiles attached to that shard. **A single
`VELORKI_SEGMENTS_URL` therefore covers one shard, not the planet.** The options:

* **Point at one shard.** Works with the app exactly as it is today, and is
  enough for any regional build — run the workflow with a `filter` covering the
  area you ship (e.g. all of Europe is far under 900 tiles) and everything lands
  in shard 1.
* **Teach the app several base URLs.** `latest.json` already lists every shard
  with its base URL and tile count, so the app could read it, merge the shard
  manifests, and resolve a tile to the shard that holds it. This is the only way
  to serve the whole planet from this mirror, and it is a change in the app, not
  here.
* **Raise `SHARD_TILES`.** Only if GitHub ever raises the 1000-asset cap. The
  script defaults to 900 to leave room for `manifest.json`, `manifest.tsv` and
  upstream growth.

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
* **The routing tiles** (`.rd5` release assets) are **not** ours. They are
  derived from OpenStreetMap data and are therefore licensed under the
  [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/):

  > © OpenStreetMap contributors, ODbL 1.0.

  They are produced by [BRouter](https://github.com/abrensch/brouter) and
  mirrored from <https://brouter.de/brouter/segments4/>, which is the upstream
  and the authoritative source. This repository adds nothing to them — it only
  copies them, hashes them and re-publishes them so app traffic does not land on
  brouter.de.

Anything that displays or routes on this data must carry the OpenStreetMap
attribution.
