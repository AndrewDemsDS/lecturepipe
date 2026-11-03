#!/usr/bin/env python3
"""Read the phone app's recording info file (<stem>.json next to the audio).

Prints one "key=value" line per field that passed its check, for lecture-transcribe
to read. A field that fails its check is reported on stderr and left out; a file
that is not a small JSON object gives no lines at all. Always exits 0 unless the
command line is wrong: a bad info file must never stop a transcription.

Keys: course (the course code rule), date (YYYY-MM-DD), kind (lecture, lab or
recitation), number (1 to 99, or null), topic (any text, may be empty), language
(a whisper code or "auto"). Anything else is ignored.
"""
import datetime, json, re, sys

MAX_BYTES = 64 * 1024
COURSE = re.compile(r"[A-Za-z][A-Za-z0-9-]{1,11}")
LANG = re.compile(r"auto|[a-z]{2,3}")
KINDS = ("lecture", "lab", "recitation")


def warn(msg):
    print(f"  ! recording info: {msg}", file=sys.stderr)


def no_dupes(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("a key appears twice")
    return dict(pairs)


def fields(doc):
    out = {}
    v = doc.get("course")
    if v is not None:
        if isinstance(v, str) and COURSE.fullmatch(v):
            out["course"] = v.upper()
        else:
            warn("course is not a course code, ignored")
    v = doc.get("date")
    if v is not None:
        try:
            if not (isinstance(v, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", v)):
                raise ValueError
            datetime.date.fromisoformat(v)
            out["date"] = v
        except ValueError:
            warn("date is not YYYY-MM-DD, ignored")
    v = doc.get("kind")
    if v is not None:
        if v in KINDS:
            out["kind"] = v
        else:
            warn("kind is not lecture, lab or recitation, ignored")
    if "number" in doc:
        v = doc["number"]
        # bool is an int in Python, and true is not a lecture number.
        if v is None:
            out["number"] = ""
        elif isinstance(v, int) and not isinstance(v, bool) and 1 <= v <= 99:
            out["number"] = str(v)
        else:
            warn("number is not 1 to 99 or null, ignored")
    v = doc.get("topic")
    if v is not None:
        if isinstance(v, str):
            # One line, no control characters, a sane length.
            t = " ".join("".join(c if c.isprintable() else " " for c in v).split())[:200]
            out["topic"] = t
        else:
            warn("topic is not text, ignored")
    v = doc.get("language")
    if v is not None:
        if isinstance(v, str) and LANG.fullmatch(v):
            out["language"] = v
        else:
            warn("language is not a whisper code, ignored")
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: recinfo.py FILE.json", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1], "rb") as f:
            raw = f.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise ValueError("larger than 64 KiB")
        doc = json.loads(raw.decode("utf-8"), object_pairs_hook=no_dupes,
                         parse_constant=lambda c: (_ for _ in ()).throw(ValueError(c)))
        if not isinstance(doc, dict):
            raise ValueError("not a JSON object")
    except (OSError, UnicodeDecodeError, ValueError, RecursionError) as e:
        warn(f"{sys.argv[1].rsplit('/', 1)[-1]} not read ({e}), using the file name")
        return 0
    for k, v in fields(doc).items():
        print(f"{k}={v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
