#!/usr/bin/env python3
"""
Rename [Judas] One Piece files to include episode titles.
Before: [Judas] One Piece - 001.mkv
After:  [Judas] One Piece - 001 - I'm Luffy! The Man Who Will Become the Pirate King!.mkv
"""

import json
import re
import sys
import urllib.request
from pathlib import Path

JUDAS_ROOT = Path(
    "/home/michaelr/media-stack/data/torrents"
    "/[Judas] One Piece 001-574 [1080p][HEVC x265 10bit][Dual-Audio][Eng-Subs]"
)
SUBDIRS = [
    JUDAS_ROOT / "[Judas] One Piece 001-206 [4x3]",
    JUDAS_ROOT / "[Judas] One Piece 207-574 [16x9]",
]

TVMAZE_EPISODES_URL = "https://api.tvmaze.com/shows/1505/episodes"
FILE_PATTERN = re.compile(r"^\[Judas\] One Piece - (\d{3})\.mkv$")

# Characters that are unsafe in filenames
UNSAFE = re.compile(r'[<>:"/\\|?*]')


def sanitize(name: str) -> str:
    # Replace colons with a dash (common convention), strip other unsafe chars
    name = name.replace(": ", " - ").replace(":", "-")
    name = UNSAFE.sub("", name)
    return name.strip()


def fetch_episodes() -> dict[int, str]:
    print("Fetching episode list from TVMaze...", flush=True)
    with urllib.request.urlopen(TVMAZE_EPISODES_URL, timeout=30) as resp:
        episodes = json.load(resp)
    # TVMaze returns episodes in broadcast order; sequential index = absolute number
    ep_map = {}
    for i, ep in enumerate(episodes, 1):
        ep_map[i] = ep["name"]
    print(f"  Got {len(ep_map)} episodes.")
    return ep_map


def collect_files() -> list[tuple[Path, int]]:
    files = []
    for subdir in SUBDIRS:
        for f in sorted(subdir.iterdir()):
            m = FILE_PATTERN.match(f.name)
            if m:
                files.append((f, int(m.group(1))))
    return files


def main():
    dry_run = "--dry-run" in sys.argv or "-n" in sys.argv
    if dry_run:
        print("DRY RUN — no files will be renamed.\n")

    ep_map = fetch_episodes()
    files = collect_files()

    if not files:
        print("No matching files found.")
        return

    missing, renamed, skipped = [], 0, 0
    for path, ep_num in files:
        title = ep_map.get(ep_num)
        if not title:
            missing.append(ep_num)
            continue

        safe_title = sanitize(title)
        new_name = f"[Judas] One Piece - {ep_num:03d} - {safe_title}.mkv"
        new_path = path.parent / new_name

        if new_path == path:
            skipped += 1
            continue

        print(f"  {path.name}")
        print(f"  → {new_name}")
        if not dry_run:
            path.rename(new_path)
        renamed += 1

    print(f"\n{'Would rename' if dry_run else 'Renamed'}: {renamed}")
    print(f"Skipped (already named): {skipped}")
    if missing:
        print(f"No title found for episode(s): {missing}")


if __name__ == "__main__":
    main()
