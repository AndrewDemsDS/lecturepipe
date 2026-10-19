#!/usr/bin/env python3
"""Append one SRT to another, shifting its timestamps by an offset in seconds
and renumbering the cues. Used by lecture-live to stitch per-segment output.

    srtshift.py --offset 300 --append combined.srt segment.srt
"""
import argparse
import re

TIMING = re.compile(r"(\d{2}):(\d{2}):(\d{2})[,.](\d{3}) --> (\d{2}):(\d{2}):(\d{2})[,.](\d{3})")


def hms(ms):
    ms = max(0, int(round(ms)))
    h, rem = divmod(ms, 3600000)
    m, rem = divmod(rem, 60000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def cues(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    for block in re.split(r"\n\s*\n", text.strip()):
        lines = block.strip().split("\n")
        if len(lines) < 2:
            continue
        idx = 1 if lines[0].strip().isdigit() else 0
        m = TIMING.match(lines[idx].strip())
        if not m:
            continue
        g = [int(x) for x in m.groups()]
        start = (g[0] * 3600 + g[1] * 60 + g[2]) * 1000 + g[3]
        end = (g[4] * 3600 + g[5] * 60 + g[6]) * 1000 + g[7]
        body = "\n".join(lines[idx + 1:]).strip()
        if body:
            yield start, end, body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("segment")
    ap.add_argument("--offset", type=float, default=0.0, help="seconds to add")
    ap.add_argument("--append", required=True, help="combined SRT to append to")
    a = ap.parse_args()
    n = 0
    try:
        with open(a.append, encoding="utf-8") as fh:
            n = sum(1 for line in fh if line.strip().isdigit())
    except FileNotFoundError:
        pass
    off = a.offset * 1000
    with open(a.append, "a", encoding="utf-8") as out:
        for start, end, body in cues(a.segment):
            n += 1
            out.write(f"{n}\n{hms(start + off)} --> {hms(end + off)}\n{body}\n\n")
    print(n)


if __name__ == "__main__":
    main()
