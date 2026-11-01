#!/usr/bin/env python3
"""The snapshot pointers: when a snapshot is complete, moving latest.json, pruning.

Called by scripts/promote-snapshot.sh; each subcommand does one thing.

    snapshot.py carry   --quarantine Q --live L --tag T --shards "T T-s2" --repo R
                        --gazetteer-dir G --into M --scope S --work W --out O
    snapshot.py state   --pending P --result R --scope S --run URL --out O
    snapshot.py check   --pending P --live L --repo R
    snapshot.py record  --pointer P [--pointer-dir rehearsal/]  (cwd: a checkout of main)
    snapshot.py promote --pointer P [--pointer-dir rehearsal/]  (cwd: a checkout of main)
    snapshot.py rd5-digest FILE...  (the content digest publish-tiles puts in manifests)
    snapshot.py prune   --dir D --repo R --keep N [--tag-prefix rehearsal-] [--dry-run]

Why it looks like this
----------------------
  * latest.json is what every app follows, so it only ever names a complete
    snapshot: every rd5 and every gazetteer uploaded and listed in the shard
    manifests. publish-tiles writes the new snapshot to pending.json instead;
    publish-gazetteer promotes it once it is complete.
  * Which regions are still missing is kept in pending.json itself, under
    `gazetteer.missingRegions`: a world run sets it, a custom run (which
    merges with the published tiles) strikes the regions it built. A region
    that failed only shows as rows missing from a tile its neighbours also
    fill, so the tiles alone cannot tell a complete snapshot from a gap.
  * The tiles are checked as well, against the live snapshot: a tile that had
    an rd5 or a gazetteer there and has none here blocks the promotion. A tile
    that had no gazetteer there either (sea, ice, land without an extract) is
    listed and is fine.
  * A quarantined tile (merge.py could not merge or check it) keeps last
    month's search: `carry` copies the live snapshot's `.gaz` of that tile
    into the merged files, so it is uploaded and listed like any other and
    the check above passes. Such tiles are recorded under
    `gazetteer.carriedOver`, which stays in latest.json after the move.
  * Pruning never deletes what an app may be reading: the snapshots named by
    latest.json, pending.json, next.json and keep-tags.txt, any snapshot
    published after the live one (an upload still running, or one waiting for
    its gazetteers), and the newest --keep up to and including the live one
    (so the snapshot apps followed until the last promotion stays a while).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile

STATE_KEY = "gazetteer"


def log(message: str) -> None:
    print(message, file=sys.stderr)


def load(path: str) -> dict | None:
    if not path or not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def dump(data: dict, path: str) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, stdout=subprocess.PIPE, text=True).stdout


def shard_tags(pointer: dict) -> list[str]:
    tags = [shard["tag"] for shard in pointer.get("shards", []) if shard.get("tag")]
    return tags or [pointer["tag"]]


def snapshot_of(tag: str) -> str:
    return re.sub(r"-s[0-9]+$", "", tag)


# ------------------------------------------------------------------- carry ---
def gazetteer_entries(repo: str, tags: list[str]) -> dict[str, tuple[str, dict]]:
    """tile -> (shard tag, gazetteer object) for every tile with a .gaz."""
    found: dict[str, tuple[str, dict]] = {}
    for tag in tags:
        try:
            entries = manifest(repo, tag).get("tiles", [])
        except subprocess.CalledProcessError:
            log(f"warning: no manifest for {tag}")
            continue
        for entry in entries:
            if entry.get("gazetteer") and entry.get("tile") not in found:
                found[entry["tile"]] = (tag, entry["gazetteer"])
    return found


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def rd5_digest(path: str) -> str:
    """sha256 of an rd5 with its footer creation time zeroed, as lower-case hex.

    Every monthly rebuild stamps an 8-byte big-endian creationTime (ms) at
    byte offset fileIndex[24], the 25th of the 25 header longs, masked to 48
    bits (bytes 192..200); the rest is deterministic. The app computes the
    same digest, so this is the definition: the 8 bytes at that offset are
    replaced by zeros when the file reaches fileIndex[24] + 8, otherwise the
    file is hashed unchanged.
    """
    size = os.path.getsize(path)
    start = -1
    with open(path, "rb") as handle:
        header = handle.read(200)
        if len(header) == 200:
            start = int.from_bytes(header[192:200], "big") & 0xFFFFFFFFFFFF
        if start < 0 or size < start + 8:
            start = -1
        digest = hashlib.sha256()
        handle.seek(0)
        position = 0
        while True:
            block = handle.read(1 << 20)
            if not block:
                break
            if start >= 0 and position < start + 8 and position + len(block) > start:
                low = max(start - position, 0)
                high = min(start + 8 - position, len(block))
                block = block[:low] + bytes(high - low) + block[high:]
            digest.update(block)
            position += len(block)
    return digest.hexdigest()


def cmd_rd5_digest(args: argparse.Namespace) -> int:
    for path in args.files:
        print(f"{rd5_digest(path)}  {path}")
    return 0


def fetch_previous(repo: str, tile: str, tag: str, want: dict, work: str, gazetteer_dir: str) -> tuple[str, str]:
    """Download the live snapshot's <tile>.gaz and prove it is that file.

    Returns (path, note). Raises RuntimeError when it is not usable: not the
    bytes its manifest names, or not a version 1 gazetteer of this tile -
    what an app needs to open it. check.py runs as well; a file that fails
    only today's stricter checks is still carried, because it is the very
    file riders have now and dropping it would leave them with none.
    """
    directory = os.path.join(work, tag)
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, f"{tile}.gaz")
    gh("release", "download", tag, "--repo", repo, "--pattern", f"{tile}.gaz",
       "--dir", directory, "--clobber")
    size = os.path.getsize(path)
    if size != want.get("bytes"):
        raise RuntimeError(f"{tag}/{tile}.gaz is {size} bytes, its manifest says {want.get('bytes')}")
    if want.get("sha256") and sha256_of(path) != want["sha256"]:
        raise RuntimeError(f"{tag}/{tile}.gaz does not match the sha256 in its manifest")
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        meta = dict(db.execute("SELECT key, value FROM meta"))
    except sqlite3.Error as error:
        raise RuntimeError(f"{tag}/{tile}.gaz does not open: {error}") from error
    finally:
        db.close()
    if meta.get("schema_version") != "1" or meta.get("tile") != tile:
        raise RuntimeError(
            f"{tag}/{tile}.gaz is schema {meta.get('schema_version')!r} of tile {meta.get('tile')!r}")
    sys.path.insert(0, gazetteer_dir)
    try:
        from check import check  # noqa: PLC0415 - the app repo's, found at run time
        check(path)
    except Exception as error:  # noqa: BLE001 - see the docstring
        return path, f"fails today's check.py ({error}); carried anyway, riders have this file now"
    finally:
        sys.path.remove(gazetteer_dir)
    return path, ""


def cmd_carry(args: argparse.Namespace) -> int:
    """Give every quarantined tile a .gaz: this snapshot's own, or the live one's.

    Writes {tile: {outcome, reason, from?, note?}} to --out, with outcome
      kept     the release already has one and this run does not replace it
               (a custom run, which merges into what is published);
      carried  the live snapshot's file, verified and copied into --into;
      none     neither has one: the tile goes without, as a sea tile does;
      failed   the live snapshot has one but it could not be carried; the
               snapshot check will then refuse to promote.
    """
    report = load(args.quarantine) or {}
    quarantined = {q["tile"]: q.get("reason", "") for q in report.get("quarantined", [])}
    outcomes: dict[str, dict] = {}
    if not quarantined:
        dump(outcomes, args.out)
        return 0
    os.makedirs(args.work, exist_ok=True)
    here = gazetteer_entries(args.repo, args.shards.split())
    live = load(args.live)
    previous: dict[str, tuple[str, dict]] = {}
    if live and live.get("tag") and live["tag"] != args.tag:
        previous = gazetteer_entries(args.repo, shard_tags(live))

    for tile, reason in sorted(quarantined.items()):
        outcome = {"reason": reason}
        if args.scope == "custom" and tile in here:
            outcome.update(outcome="kept", note=f"the file already on {here[tile][0]} stays")
        elif tile in previous:
            tag, want = previous[tile]
            try:
                path, note = fetch_previous(args.repo, tile, tag, want, args.work, args.gazetteer_dir)
                shutil.copyfile(path, os.path.join(args.into, f"{tile}.gaz"))
                outcome.update(outcome="carried", **{"from": tag})
                if note:
                    outcome["note"] = note
            except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
                outcome.update(outcome="failed", note=f"could not carry over from {tag}: {error}")
        elif tile in here:
            outcome.update(outcome="kept", note=f"the file already on {here[tile][0]} stays")
        else:
            outcome.update(outcome="none", note="no earlier .gaz for this tile")
        outcomes[tile] = outcome
        log(f"{tile}: {outcome['outcome']} - {outcome.get('note', '')}")
    dump(outcomes, args.out)
    return 0


# ------------------------------------------------------------------- state ---
def cmd_state(args: argparse.Namespace) -> int:
    """The pending pointer with this run's regions folded into its state.

    Prints the number of regions still missing, or `none` when no world run
    has finished into the snapshot yet."""
    pending = load(args.pending)
    result = load(args.result) or {}
    built = set(result.get("built", []))
    missing_now = set(result.get("missing", []))
    state = pending.get(STATE_KEY)

    carried = result.get("carriedOver", {})
    quarantined = result.get("quarantined", {})
    if args.scope == "world":
        # A world run rebuilds every tile from scratch: what it missed is the gap.
        state = {"missingRegions": sorted(missing_now), "carriedOver": carried,
                 "quarantined": quarantined}
    elif args.scope == "custom" and state is not None:
        # A custom run merges with the published tiles, so the regions it built
        # are in the snapshot now; one it failed was there before or is still listed.
        # A tile carried over earlier still holds last month's rows (a custom
        # run merges into it), so it stays listed until a world run.
        state = {
            "missingRegions": sorted(set(state.get("missingRegions", [])) - built),
            "carriedOver": {**state.get("carriedOver", {}), **carried},
            "quarantined": {**state.get("quarantined", {}), **quarantined},
        }
    # europe / north-america rebuild their tiles without the neighbours' rows:
    # they neither complete a snapshot nor are counted towards it.

    if state is not None:
        for key in ("carriedOver", "quarantined"):
            if not state[key]:
                del state[key]
        state["updatedBy"] = args.run
        pending[STATE_KEY] = state
    dump(pending, args.out)
    print("none" if state is None else len(state["missingRegions"]))
    return 0


# ------------------------------------------------------------------- check ---
def release_assets(repo: str, tag: str) -> dict[str, tuple[int, str]]:
    release_id = gh("api", f"repos/{repo}/releases/tags/{tag}", "--jq", ".id").strip()
    lines = gh(
        "api", "--paginate", f"repos/{repo}/releases/{release_id}/assets?per_page=100",
        "--jq", '.[] | "\\(.name)\\t\\(.size)\\t\\((.digest // "") | ltrimstr("sha256:"))"',
    )
    assets = {}
    for line in lines.splitlines():
        if line:
            name, size, sha = line.split("\t")
            assets[name] = (int(size), sha)
    return assets


def manifest(repo: str, tag: str) -> dict:
    with tempfile.TemporaryDirectory() as directory:
        gh("release", "download", tag, "--repo", repo, "--pattern", "manifest.json",
           "--dir", directory, "--clobber")
        return load(os.path.join(directory, "manifest.json")) or {}


def cmd_check(args: argparse.Namespace) -> int:
    """Exit 0 when the pending snapshot may become the live one."""
    pending = load(args.pending)
    live = load(args.live)
    problems: list[str] = []
    have_rd5: set[str] = set()
    have_gaz: set[str] = set()

    for tag in shard_tags(pending):
        try:
            entries = manifest(args.repo, tag).get("tiles", [])
            assets = release_assets(args.repo, tag)
        except subprocess.CalledProcessError as error:
            problems.append(f"{tag}: could not read the release ({error})")
            continue
        want = next((s.get("tileCount") for s in pending.get("shards", []) if s.get("tag") == tag), None)
        if want is not None and want != len(entries):
            problems.append(f"{tag}: manifest lists {len(entries)} tiles, pending.json {want}")
        for entry in entries:
            tile = entry["tile"]
            for kind, want_entry in (("rd5", entry), ("gaz", entry.get("gazetteer"))):
                if not want_entry:
                    continue
                name = f"{tile}.{kind}"
                size, sha = assets.get(name, (None, ""))
                if size is None:
                    problems.append(f"{name}: in the manifest of {tag}, not on the release")
                elif size != want_entry.get("bytes"):
                    problems.append(f"{name}: asset {size} bytes, manifest {want_entry.get('bytes')}")
                elif sha and want_entry.get("sha256") and sha != want_entry["sha256"]:
                    problems.append(f"{name}: asset sha256 differs from the manifest")
                else:
                    (have_rd5 if kind == "rd5" else have_gaz).add(tile)

    live_rd5: set[str] = set()
    live_gaz: set[str] = set()
    if live and live.get("tag") != pending.get("tag"):
        for tag in shard_tags(live):
            try:
                entries = manifest(args.repo, tag).get("tiles", [])
            except subprocess.CalledProcessError:
                log(f"warning: no manifest for the live shard {tag}; not compared")
                continue
            for entry in entries:
                live_rd5.add(entry["tile"])
                if entry.get("gazetteer"):
                    live_gaz.add(entry["tile"])

    lost_rd5 = sorted(live_rd5 - have_rd5)
    lost_gaz = sorted((live_gaz & have_rd5) - have_gaz)
    without = sorted(have_rd5 - have_gaz - live_gaz)

    def show(title: str, tiles: list[str]) -> None:
        if tiles:
            print(f"{title} ({len(tiles)}):")
            for start in range(0, len(tiles), 12):
                print("  " + " ".join(tiles[start:start + 12]))

    print(f"{pending['tag']}: {len(have_rd5)} tiles, {len(have_gaz)} with a gazetteer")
    show("Tiles without a gazetteer here or in the live snapshot (no OSM extract covers them)", without)
    show("Tiles the live snapshot has and this one lacks", lost_rd5)
    show("Tiles whose gazetteer the live snapshot has and this one lacks", lost_gaz)
    for line in problems:
        print("  " + line)
    if problems or lost_rd5 or lost_gaz:
        print("not complete: latest.json stays where it is")
        return 1
    print("complete")
    return 0


# ------------------------------------------------------- edits on a checkout ---
# These run inside a fresh checkout of main (scripts/commit-to-main.sh), so
# they edit the files as they are now, not as they were when the run started.
def cmd_record(args: argparse.Namespace) -> int:
    """Write the pending pointer's new state, if pending.json still names it."""
    pointer = load(args.pointer)
    pending = args.pointer_dir + "pending.json"
    current = load(pending)
    if not current or current.get("tag") != pointer["tag"]:
        log(f"{pending} no longer names {pointer['tag']}; state not recorded")
        return 0
    dump(pointer, pending)
    return 0


def cmd_promote(args: argparse.Namespace) -> int:
    pointer = load(args.pointer)
    # The progress goes; which tiles hold last month's search stays on record.
    state = pointer.pop(STATE_KEY, None) or {}
    kept = {key: state[key] for key in ("carriedOver", "quarantined") if state.get(key)}
    if kept:
        pointer[STATE_KEY] = kept
    names = {name: args.pointer_dir + name for name in ("latest.json", "pending.json", "next.json")}
    live = load(names["latest.json"])
    if live and live.get("tag") != pointer["tag"] and live.get("generatedAt", "") > pointer.get("generatedAt", ""):
        log(f"{names['latest.json']} already names the newer {live['tag']}; {pointer['tag']} is not promoted")
        return 0
    dump(pointer, names["latest.json"])
    current = load(names["pending.json"])
    if current and current.get("tag") == pointer["tag"]:
        os.remove(names["pending.json"])
    # next.json held a format the live apps could not read; once latest.json
    # is in that format it has nothing left to say.
    upcoming = load(names["next.json"])
    if upcoming and upcoming.get("formatVersion") == pointer.get("formatVersion"):
        os.remove(names["next.json"])
    return 0


# ------------------------------------------------------------------- prune ---
def cmd_prune(args: argparse.Namespace) -> int:
    pointers = {name: load(os.path.join(args.dir, name)) for name in ("latest.json", "pending.json", "next.json")}
    live = pointers["latest.json"]
    if not live or not live.get("tag"):
        log("no latest.json: refusing to prune")
        return 1
    if not live["tag"].startswith(args.tag_prefix):
        log(f"latest.json names {live['tag']}, not a {args.tag_prefix}* snapshot: refusing to prune")
        return 1

    releases = json.loads(gh("release", "list", "--repo", args.repo, "--limit", "200",
                             "--json", "tagName,publishedAt"))
    published: dict[str, str] = {}
    for release in releases:
        tag = release["tagName"]
        if not tag.startswith(args.tag_prefix):
            continue
        snapshot = snapshot_of(tag)
        stamp = release.get("publishedAt") or ""
        published[snapshot] = min(published.get(snapshot, stamp), stamp)
    if live["tag"] not in published:
        log(f"the live snapshot {live['tag']} has no release: refusing to prune")
        return 1

    keep: dict[str, str] = {}
    for name, pointer in pointers.items():
        if pointer and pointer.get("tag"):
            keep.setdefault(snapshot_of(pointer["tag"]), name)
    keep_file = os.path.join(args.dir, "keep-tags.txt")
    if os.path.isfile(keep_file):
        for line in open(keep_file, encoding="utf-8"):
            tag = re.sub(r"#.*", "", line).strip()
            if tag:
                keep.setdefault(snapshot_of(tag), "keep-tags.txt")
    newest = sorted(published, key=lambda s: published[s], reverse=True)
    live_at = published[live["tag"]]
    for snapshot in newest:
        if published[snapshot] > live_at:
            keep.setdefault(snapshot, "newer than the live snapshot")
    # The budget counts from the live snapshot down, so an upload in flight
    # never pushes out the snapshot apps followed until a moment ago.
    for snapshot in [s for s in newest if published[s] <= live_at][: max(0, args.keep)]:
        keep.setdefault(snapshot, f"newest {args.keep} up to the live one")

    for snapshot in newest:
        if snapshot in keep:
            print(f"keep   {snapshot} ({keep[snapshot]})")
    status = 0
    for release in releases:
        tag = release["tagName"]
        if not tag.startswith(args.tag_prefix) or snapshot_of(tag) in keep:
            continue
        print(f"delete {tag}")
        if args.dry_run:
            continue
        done = subprocess.run(["gh", "release", "delete", tag, "--repo", args.repo, "--yes", "--cleanup-tag"])
        if done.returncode != 0:
            log(f"warning: could not delete {tag}")
            status = 1
    return status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    carry = sub.add_parser("carry")
    carry.add_argument("--quarantine", required=True, help="merge.py's quarantine.json")
    carry.add_argument("--live", default="", help="the live pointer (latest.json)")
    carry.add_argument("--tag", required=True, help="the snapshot being published")
    carry.add_argument("--shards", required=True, help="its shard tags, space-separated")
    carry.add_argument("--repo", required=True)
    carry.add_argument("--gazetteer-dir", required=True, help="tools/gazetteer, for check.py")
    carry.add_argument("--into", required=True, help="the merged files' directory")
    carry.add_argument("--scope", required=True)
    carry.add_argument("--work", required=True)
    carry.add_argument("--out", required=True)
    carry.set_defaults(run_command=cmd_carry)

    state = sub.add_parser("state")
    state.add_argument("--pending", required=True)
    state.add_argument("--result", required=True)
    state.add_argument("--scope", required=True)
    state.add_argument("--run", default="")
    state.add_argument("--out", required=True)
    state.set_defaults(run_command=cmd_state)

    check = sub.add_parser("check")
    check.add_argument("--pending", required=True)
    check.add_argument("--live", default="")
    check.add_argument("--repo", required=True)
    check.set_defaults(run_command=cmd_check)

    for name, function in (("record", cmd_record), ("promote", cmd_promote)):
        edit = sub.add_parser(name)
        edit.add_argument("--pointer", required=True)
        edit.add_argument("--pointer-dir", default="", help="'rehearsal/' for a rehearsal")
        edit.set_defaults(run_command=function)

    rd5 = sub.add_parser("rd5-digest")
    rd5.add_argument("files", nargs="+")
    rd5.set_defaults(run_command=cmd_rd5_digest)

    prune = sub.add_parser("prune")
    prune.add_argument("--dir", required=True, help="directory holding main's pointer files")
    prune.add_argument("--repo", required=True)
    prune.add_argument("--keep", type=int, default=2)
    prune.add_argument("--tag-prefix", default="tiles-", help="only releases with this prefix")
    prune.add_argument("--dry-run", action="store_true")
    prune.set_defaults(run_command=cmd_prune)

    args = parser.parse_args()
    return args.run_command(args)


if __name__ == "__main__":
    raise SystemExit(main())
