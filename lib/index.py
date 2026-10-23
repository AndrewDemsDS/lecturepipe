#!/usr/bin/env python3
"""Rebuild INDEX.md from the transcripts under <root>/transcripts/<COURSE>/."""
import datetime
import os
import re
import sys


def main():
    root = sys.argv[1]
    tdir = os.path.join(root, "transcripts")
    rows = {}
    courses = sorted(os.listdir(tdir)) if os.path.isdir(tdir) else []
    for course in courses:
        cd = os.path.join(tdir, course)
        if not os.path.isdir(cd):
            continue
        for f in sorted(os.listdir(cd)):
            if not f.endswith(".md"):
                continue
            p = os.path.join(cd, f)
            with open(p, encoding="utf-8") as fh:
                doc = fh.read(2000)
            g = dict(re.findall(r"^(date|title|duration|words|notes_status):[ \t]*(\S.*?)[ \t]*$", doc, re.M))
            rows.setdefault(course, []).append({
                "path": os.path.relpath(p, root),
                "date": g.get("date", "?"),
                "title": g.get("title", "").strip('"') or f[:-3],
                "dur": g.get("duration", "?"),
                "words": g.get("words", "?"),
                "notes": g.get("notes_status", "?").split()[0],
            })

    out = ["# Lectures", "",
           f"_Rebuilt {datetime.datetime.now():%Y-%m-%d %H:%M} by lecture-index._", ""]
    total = sum(len(v) for v in rows.values())
    out += [f"**{total}** lecture(s) across **{len(rows)}** course(s).", ""]
    for course, items in sorted(rows.items()):
        out += [f"## {course}", "", "| Date | Lecture | Length | Words | Notes |",
                "|---|---|---|---|---|"]
        for r in sorted(items, key=lambda x: x["date"], reverse=True):
            mark = {"done": "✅", "pending": "⏳"}.get(r["notes"], "—")
            out.append(f"| {r['date']} | [{r['title']}]({r['path']}) | {r['dur']} | {r['words']} | {mark} |")
        out.append("")
    with open(os.path.join(root, "INDEX.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    print(f"indexed {total} lecture(s) → {os.path.join(root, 'INDEX.md')}")


if __name__ == "__main__":
    main()
