#!/usr/bin/env python3
"""Turn a whisper.cpp SRT into a readable, linkable lecture note.

Whisper emits one cue every few seconds; reading that is miserable. This
regroups cues into paragraphs at sentence boundaries or after a long pause,
and stamps each paragraph with the time it starts so you can jump back to
the audio.
"""
import argparse, collections, re, datetime

CUE = re.compile(r"^(\d+)\s*$")
TIMING = re.compile(r"(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})")

def parse(path):
    blocks, cur = [], None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        m = TIMING.match(line.strip())
        if m:
            g = [int(x) for x in m.groups()]
            cur = {"start": g[0]*3600+g[1]*60+g[2]+g[3]/1000,
                   "end":   g[4]*3600+g[5]*60+g[6]+g[7]/1000, "text": []}
            blocks.append(cur)
        elif line.strip() and cur is not None and not CUE.match(line.strip()):
            cur["text"].append(line.strip())
    for b in blocks:
        b["text"] = " ".join(b["text"]).strip()
    return [b for b in blocks if b["text"]]

def hms(s):
    s = int(s)
    return f"{s//3600:02d}:{s%3600//60:02d}:{s%60:02d}"

# Greek and Latin sentence enders. Note ";" is the Greek question mark.
ENDS = tuple(".;!?;…")

def paragraphs(blocks, gap=2.0, max_chars=700):
    out, buf, start = [], [], None
    for i, b in enumerate(blocks):
        if start is None:
            start = b["start"]
        buf.append(b["text"])
        nxt = blocks[i+1] if i+1 < len(blocks) else None
        joined = " ".join(buf)
        pause = (nxt["start"] - b["end"]) if nxt else 999
        if (b["text"].endswith(ENDS) and len(joined) > 280) or pause > gap or len(joined) > max_chars or nxt is None:
            out.append((start, joined))
            buf, start = [], None
    return out

def main():
    p = argparse.ArgumentParser()
    for f in ("srt", "out", "course", "date", "title", "lang", "model", "source"):
        p.add_argument(f"--{f}", required=True)
    p.add_argument("--duration", type=int, default=0)
    a = p.parse_args()

    blocks = parse(a.srt)
    paras = paragraphs(blocks)
    words = sum(len(t.split()) for _, t in paras)

    # Whisper can lock into a repetition loop and emit the same cue for many
    # minutes. That looks like a normal transcript unless you go looking, so
    # measure it and say so loudly rather than filing silent garbage.
    loop_note = ""
    if blocks:
        texts = [b["text"] for b in blocks]
        top, n = collections.Counter(texts).most_common(1)[0]
        ratio = n / len(texts)
        if n >= 10 and ratio >= 0.15:
            loop_note = (f'repetition_warning: "{n} of {len(texts)} segments identical '
                         f'({ratio:.0%}) — likely a decoder loop; re-run this lecture"')
            print(f"  !! REPETITION LOOP: {n}/{len(texts)} segments ({ratio:.0%}) are "
                  f"{top[:60]!r}", flush=True)
    title = a.title.replace("-", " ").replace("_", " ").strip() or "Lecture"

    fm = [
        "---",
        f"course: {a.course}",
        f"date: {a.date}",
        f'title: "{title}"',
        f"duration: {hms(a.duration)}",
        f"words: {words}",
        f"language: {a.lang}",
        f"asr_model: whisper-large-v3{'-turbo' if a.model=='turbo' else ''}",
        f'audio: "{a.source}"',
        f"transcribed: {datetime.date.today().isoformat()}",
        "tags: [lecture, transcript]",
        *([loop_note] if loop_note else []),
        "notes_status: pending",
        "---",
        "",
        f"# {a.course} {a.date}",
        "",
        "<!-- LECTURE-NOTES-START -->",
        "<!-- LECTURE-NOTES-END -->",
        "",
        "## Transcript",
        "",
    ]
    body = [f"**[{hms(s)}]** {t}\n" for s, t in paras]
    open(a.out, "w", encoding="utf-8").write("\n".join(fm) + "\n".join(body))
    print(f"  {len(paras)} paragraphs, {words} words")

if __name__ == "__main__":
    main()
