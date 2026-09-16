#!/usr/bin/env python3
"""Plan the gazetteer build: pick Geofabrik extracts and balance them into groups.

    gazetteer-plan.py --scope europe --dry-run
    gazetteer-plan.py --scope custom --regions "europe/liechtenstein europe/portugal"

Writes a GitHub Actions matrix to $GITHUB_OUTPUT (and to stdout without it):

    {"group": [{"name": "g01", "regions": "europe/albania europe/andorra"}, ...]}

Why it looks like this
----------------------
  * One extract at a time, one group per runner. A runner has ~14 GB of free
    disk and 16 GB of RAM, which is less than the planet PBF and less than any
    continent PBF, so the planet is built from the *leaf* extracts Geofabrik
    already cuts (the largest is a few GB) and the tiles are merged afterwards.
  * Balanced by bytes, not by count. Build time is roughly linear in PBF size
    (~6-9 MB/s on one core), so groups of equal byte totals finish together and
    the slowest group sets the wall clock.
  * At most 24 groups because a matrix job costs a runner; 24 keeps a world run
    inside a normal Actions concurrency budget while staying under the 300 min
    job timeout for the biggest group.

Geofabrik's index-v1.json identifies a region by a bare id ("act") plus a
parent ("australia"). This script uses the *path* form instead - the download
path without the "-latest.osm.pbf" suffix, e.g. "australia-oceania/australia/act"
or "europe/liechtenstein" - because that is what a human reads off a Geofabrik
URL and what the workflow's `regions` input takes.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

INDEX_URL = "https://download.geofabrik.de/index-v1.json"
DOWNLOAD_PREFIX = "https://download.geofabrik.de/"
PBF_SUFFIX = "-latest.osm.pbf"
USER_AGENT = (
    "velorki-data-gazetteer/1.0 "
    "(+https://github.com/orkitec/velorki-data; offline search index builder)"
)
MAX_GROUPS = 24

# Scope names the workflow offers, mapped to the top-level path prefix they
# select. "world" is every leaf; "custom" takes the ids it is given verbatim.
SCOPES = {
    "world": None,
    "europe": "europe",
    "north-america": "north-america",
}


# Geofabrik also publishes convenience extracts that are unions of regions it
# already cuts separately. They are leaves in the parent graph (nobody's child
# points at them) but every byte in them is downloaded and parsed twice, so a
# world run without this list is roughly a third longer for no extra coverage.
# Each entry is listed only because the area it covers is fully present in other
# leaves; a combination that is the *only* extract for its area (senegal-and-gambia,
# gcc-states, haiti-and-domrep, israel-and-palestine, ...) is deliberately kept.
REDUNDANT = {
    "africa/south-africa-and-lesotho",  # africa/south-africa + africa/lesotho
    "asia/sea",  # asia/{indonesia/*,malaysia-singapore-brunei,thailand,...}
    "europe/alps",  # slices of at,ch,de,fr,it,si
    "europe/britain-and-ireland",  # europe/united-kingdom/* + ireland-and-northern-ireland
    "europe/dach",  # europe/germany/* + austria + switzerland
    "europe/great-britain",  # europe/united-kingdom/{england/*,scotland,wales}
    "north-america/us-midwest",  # the five US macro-regions over north-america/us/<state>
    "north-america/us-northeast",
    "north-america/us-pacific",
    "north-america/us-south",
    "north-america/us-west",
}


class PlanError(Exception):
    """Something the caller has to fix - a bad scope, an unknown region id."""


def log(message: str) -> None:
    print(message, file=sys.stderr)


def fetch(url: str, timeout: int = 120) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def load_index(source: str) -> list[dict]:
    """The index either from Geofabrik or, for tests, from a local file."""
    if os.path.isfile(source):
        with open(source, "rb") as handle:
            raw = handle.read()
    else:
        raw = fetch(source)
    index = json.loads(raw)
    features = index.get("features")
    if not isinstance(features, list) or not features:
        raise PlanError(f"{source}: no features - did the index layout change?")
    return features


def path_of(properties: dict) -> str | None:
    """Region path derived from the pbf URL, e.g. 'europe/liechtenstein'."""
    url = (properties.get("urls") or {}).get("pbf")
    if not url or not url.startswith(DOWNLOAD_PREFIX) or not url.endswith(PBF_SUFFIX):
        return None
    return url[len(DOWNLOAD_PREFIX) : -len(PBF_SUFFIX)]


def region_paths(features: list[dict]) -> dict[str, str]:
    """path -> pbf URL, for every region the index offers a pbf for."""
    paths: dict[str, str] = {}
    for feature in features:
        properties = feature.get("properties") or {}
        path = path_of(properties)
        if path:
            paths[path] = properties["urls"]["pbf"]
    if not paths:
        raise PlanError("index held no pbf URLs - did the index layout change?")
    return paths


def leaves(paths: dict[str, str]) -> list[str]:
    """Regions nobody is a child of: the smallest extracts that still tile the world."""
    parents = {path.rsplit("/", 1)[0] for path in paths if "/" in path}
    return sorted(path for path in paths if path not in parents)


def select(paths: dict[str, str], scope: str, regions: str) -> list[str]:
    if scope == "custom":
        wanted = regions.split()
        if not wanted:
            raise PlanError("scope 'custom' needs --regions")
        # Custom ids are taken literally, leaf or not: someone asking for
        # "europe/germany" wants the one 4 GB extract, not its 16 states.
        unknown = [region for region in wanted if region not in paths]
        if unknown:
            raise PlanError("unknown region id(s): " + " ".join(unknown))
        return sorted(dict.fromkeys(wanted))

    if scope not in SCOPES:
        raise PlanError(f"unknown scope {scope!r}; pick one of {', '.join(SCOPES)}, custom")
    prefix = SCOPES[scope]
    selected = [
        path
        for path in leaves(paths)
        if path not in REDUNDANT
        and (prefix is None or path == prefix or path.startswith(prefix + "/"))
    ]
    if not selected:
        raise PlanError(f"scope {scope!r} selected no regions")
    return selected


def content_length(url: str, retries: int = 3) -> int:
    """HEAD the extract. 0 (with a warning) rather than a failed plan: an extract
    whose size is unknown still gets built, it just lands in the lightest group."""
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return int(response.headers.get("Content-Length") or 0)
        except (urllib.error.URLError, ValueError, OSError) as error:
            if attempt == retries - 1:
                log(f"warning: HEAD {url} failed ({error}); assuming 0 bytes")
    return 0


def sizes(paths: dict[str, str], selected: list[str], jobs: int) -> dict[str, int]:
    """HEAD every extract. Concurrent because these are metadata requests, not
    downloads - the downloads themselves stay strictly sequential per job."""
    with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        measured = list(pool.map(lambda region: content_length(paths[region]), selected))
    return dict(zip(selected, measured))


def balance(measured: dict[str, int], max_groups: int) -> list[dict[str, object]]:
    """Longest-processing-time-first: biggest extract into the lightest group.

    Within a few percent of optimal for this shape of input and, unlike a
    round-robin, it never puts two multi-GB extracts in the same group while
    another group holds only city-sized ones."""
    count = min(max_groups, len(measured))
    groups: list[dict[str, object]] = [
        {"name": f"g{index + 1:02d}", "regions": [], "bytes": 0} for index in range(count)
    ]
    for region, size in sorted(measured.items(), key=lambda item: (-item[1], item[0])):
        lightest = min(groups, key=lambda group: (group["bytes"], group["name"]))
        lightest["regions"].append(region)  # type: ignore[union-attr]
        lightest["bytes"] = int(lightest["bytes"]) + size  # type: ignore[arg-type]
    return groups


def mib(size: int) -> float:
    return size / 1048576.0


def print_plan(scope: str, groups: list[dict[str, object]], measured: dict[str, int]) -> None:
    total = sum(measured.values())
    print(f"scope {scope}: {len(measured)} region(s), {mib(total):,.0f} MB, {len(groups)} group(s)")
    for group in groups:
        regions = group["regions"]
        assert isinstance(regions, list)
        print(f"  {group['name']}  {mib(int(group['bytes'])):8,.0f} MB  {len(regions):3d} region(s)")
        for region in regions:
            print(f"      {mib(measured[region]):8,.1f} MB  {region}")


def emit(groups: list[dict[str, object]], measured: dict[str, int]) -> None:
    matrix = {
        "group": [
            {"name": group["name"], "regions": " ".join(group["regions"])}  # type: ignore[arg-type]
            for group in groups
        ]
    }
    line = json.dumps(matrix, separators=(",", ":"))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"matrix={line}\n")
            handle.write(f"groups={len(groups)}\n")
            handle.write(f"regions={len(measured)}\n")
            handle.write(f"bytes={sum(measured.values())}\n")
            handle.write(f"mb={mib(sum(measured.values())):.0f}\n")
    print(line)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", default="world", help="world, europe, north-america or custom")
    parser.add_argument("--regions", default="", help="space-separated ids for scope 'custom'")
    parser.add_argument("--max-groups", type=int, default=MAX_GROUPS)
    parser.add_argument("--index", default=INDEX_URL, help="index-v1.json URL or local file")
    parser.add_argument("--jobs", type=int, default=8, help="concurrent HEAD requests")
    parser.add_argument("--dry-run", action="store_true", help="print the plan, emit no matrix")
    args = parser.parse_args()

    try:
        paths = region_paths(load_index(args.index))
        selected = select(paths, args.scope, args.regions)
        log(f"{len(selected)} region(s) selected; sizing them")
        measured = sizes(paths, selected, args.jobs)
        groups = balance(measured, args.max_groups)
    except PlanError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 2
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as error:
        print(f"::error::could not read the Geofabrik index: {error}", file=sys.stderr)
        return 1

    if args.dry_run:
        print_plan(args.scope, groups, measured)
        return 0
    log(f"{len(measured)} region(s), {mib(sum(measured.values())):,.0f} MB, {len(groups)} group(s)")
    emit(groups, measured)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
