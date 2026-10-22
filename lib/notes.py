#!/usr/bin/env python3
"""Build the notes prompt for a lecture, and merge the answer back into the note.

    notes.py prompt NOTE.md --out prompt.txt [--tag-out tag] [--slides a.pdf ...] [--no-slides]
    notes.py merge  NOTE.md --generated out.md --engine TAG

The prompt is engine agnostic: plain text on stdin for whatever LLM command
the user configured. Templates live in prompts/notes.<lang>.md next to this
file and are picked by the note's `language:` frontmatter (fallback: en).
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MARK_START = "<!-- LECTURE-NOTES-START -->"
MARK_END = "<!-- LECTURE-NOTES-END -->"


def frontmatter(doc):
    m = re.match(r"---\n(.*?)\n---", doc, re.S)
    return dict(re.findall(r"^(\w+):\s*(.+)$", m.group(1) if m else "", re.M))


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def transcript_text(doc):
    body = doc.split("## Transcript", 1)[1] if "## Transcript" in doc else doc
    return re.sub(r"\*\*\[(\d\d:\d\d(?::\d\d)?)\]\*\*", r"[\1]", body).strip()


def load_template(lang):
    for cand in (lang, lang.split("-")[0], "en"):
        p = os.path.join(HERE, "prompts", f"notes.{cand}.md")
        if os.path.exists(p):
            return read(p)
    sys.exit("no prompt template found under prompts/")


def section(template, name):
    """Return the body of `<!-- section:NAME -->...<!-- /section:NAME -->`, or ''."""
    m = re.search(rf"<!-- section:{name} -->\n?(.*?)<!-- /section:{name} -->\n?", template, re.S)
    return m.group(1) if m else ""


def strip_sections(template):
    return re.sub(r"<!-- section:\w+ -->\n?.*?<!-- /section:\w+ -->\n?", "", template, flags=re.S)


def course_dirs(notes_root, course):
    """Vault folders for COURSE: "<CODE>", "<CODE> <Title>" or the older "<title>_<code>", any case.

    Dot names are skipped, like the "*/" glob in lp_vault_course_dir."""
    c = course.lower()
    out = []
    for name in sorted(os.listdir(notes_root)) if os.path.isdir(notes_root) else []:
        n = name.lower()
        if name.startswith("."):
            continue
        if os.path.isdir(os.path.join(notes_root, name)) and (n == c or n.startswith(c + " ") or n.endswith("_" + c)):
            out.append(os.path.join(notes_root, name))
    return out


def lecture_dir(note_path, course, notes_root):
    """Where this note is or will be filed. None when there is no vault."""
    real = os.path.realpath(note_path)
    sdir = os.path.dirname(real)
    if notes_root and sdir.startswith(os.path.realpath(notes_root) + os.sep):
        return sdir
    if not notes_root:
        return None
    stem = os.path.basename(note_path)[:-3]
    m = re.search(r"(?i)(lecture|lec|dialexi)[-_ ]?(\d{1,2})", stem)
    if not m:
        return None
    cands = course_dirs(notes_root, course)
    if len(cands) != 1:
        return None
    return os.path.join(cands[0], "lectures", f"{int(m.group(2)):02d}")


def siblings(note_path, sdir, notes_root):
    """Other transcripts of the same lecture: (date, title, duration, outline_lines)."""
    if not sdir or not notes_root or "/lectures/" not in sdir + "/":
        return []
    out = []
    me = os.path.realpath(note_path)
    for p in sorted(glob.glob(os.path.join(sdir, "*.md"))):
        if os.path.realpath(p) == me:
            continue
        doc = read(p)
        if MARK_START not in doc:
            continue
        fm = frontmatter(doc)
        try:
            if int(fm.get("words", "0")) < 120:
                continue
        except ValueError:
            continue
        notes_block = doc.split(MARK_START, 1)[1].split(MARK_END, 1)[0] if MARK_END in doc else ""
        outline = [l for l in notes_block.splitlines() if re.match(r"^- \*\*\[\d\d:\d\d", l)][:40]
        out.append((fm.get("date", "?"), fm.get("title", "").strip('"'), fm.get("duration", "?"), outline))
    return out


def pdf_pages(pdf):
    if not shutil.which("pdfinfo"):
        return 0
    try:
        info = subprocess.run(["pdfinfo", pdf], capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return 0
    m = re.search(r"^Pages:\s+(\d+)", info, re.M)
    return int(m.group(1)) if m else 0


def slide_text(pdf):
    """pdftotext -layout with one `=== page N ===` marker per non-empty page."""
    txt = subprocess.run(["pdftotext", "-layout", pdf, "-"], capture_output=True, text=True).stdout
    out, pending = ["=== page 1 ==="], False
    page = 1
    for line in txt.split("\n"):   # not splitlines(): it would swallow the \f page breaks
        while "\f" in line:
            line = line.replace("\f", "", 1)
            page += 1
            pending = True
        if line.strip():
            if pending:
                out.append(f"=== page {page} ===")
                pending = False
            out.append(line)
    return "\n".join(out) + "\n"


def pick_slides(args, sdir):
    if args.no_slides:
        return []
    if args.slides:
        return [p for p in args.slides if os.path.isfile(p)]
    if not sdir or not os.path.isdir(sdir):
        return []
    pdfs = sorted(glob.glob(os.path.join(sdir, "*.pdf")) + glob.glob(os.path.join(sdir, "*.PDF")))
    deck = os.path.join(sdir, os.path.basename(sdir) + ".pdf")
    if os.path.isfile(deck):
        pdfs = [deck]
    keep = []
    for p in pdfs:
        n = pdf_pages(p)
        if n > int(os.environ.get("LECTURE_SLIDES_MAX_PAGES", "150")):
            print(f"  ! skipping {os.path.basename(p)}: {n} pages", file=sys.stderr)
        else:
            keep.append(p)
    return keep


def cmd_prompt(args):
    doc = read(args.note)
    fm = frontmatter(doc)
    course, date = fm.get("course", "?"), fm.get("date", "?")
    lang = fm.get("language", "en")
    notes_root = os.environ.get("LECTURE_NOTES_ROOT", "") or None
    template = load_template(lang)

    sdir = lecture_dir(args.note, course, notes_root)
    tag = "cmd"

    sib = siblings(args.note, sdir, notes_root)
    siblings_block = ""
    if sib:
        lines = []
        for d, t, dur, outline in sib:
            lines.append(f"- {d} {t} ({dur})")
            lines += ["    " + l for l in outline]
        siblings_block = section(template, "siblings").replace("{{SIBLINGS_COUNT}}", str(len(sib))) \
            .replace("{{SIBLINGS_LIST}}", "\n".join(lines))
        print(f"  other recordings of this lecture: {len(sib)}")

    slides_rules = slides_sections = slides_block = ""
    pdfs = pick_slides(args, sdir)
    if pdfs and not shutil.which("pdftotext"):
        print("  ! pdftotext missing, writing notes from the transcript alone", file=sys.stderr)
        pdfs = []
    if pdfs:
        parts = []
        for p in pdfs:
            parts.append(f"##### {os.path.basename(p)}\n" + slide_text(p))
        text = "".join(parts)
        if sum(1 for l in text.splitlines() if l and l[0] not in "#=") > 0:
            limit = int(os.environ.get("LECTURE_SLIDES_MAX_BYTES", "300000"))
            if len(text.encode()) > limit:
                text = text.encode()[:limit].decode(errors="ignore")
                print(f"  ! slide text cut at {limit} bytes", file=sys.stderr)
            tag = "cmd+slides"
            multi = section(template, "multi_pdf").replace("{{PDF_COUNT}}", str(len(pdfs))) if len(pdfs) > 1 else ""
            slides_rules = section(template, "slides_rules").replace("{{MULTI_PDF_RULE}}", multi)
            slides_sections = section(template, "slides_sections")
            slides_block = section(template, "slides_block").replace("{{SLIDES_TEXT}}", text)
            print(f"  slides: {len(pdfs)} pdf, {text.count('=== page')} pages with text")

    body = strip_sections(template)
    prompt = (body.replace("{{COURSE}}", course).replace("{{DATE}}", date)
              .replace("{{SLIDES_RULES}}", slides_rules)
              .replace("{{SIBLINGS_BLOCK}}", siblings_block)
              .replace("{{SLIDES_SECTIONS}}", slides_sections)
              .replace("{{TRANSCRIPT}}", transcript_text(doc))
              .replace("{{SLIDES_BLOCK}}", slides_block))
    prompt = re.sub(r"\n{3,}", "\n\n", prompt)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(prompt)
    if args.tag_out:
        with open(args.tag_out, "w", encoding="utf-8") as fh:
            fh.write(tag)


def cmd_merge(args):
    doc = read(args.note)
    n = read(args.generated).strip()
    n = re.sub(r"^```(?:markdown)?\s*|\s*```$", "", n).strip()
    if not n:
        sys.exit("generated notes are empty")
    if not n.lstrip().startswith("#"):
        n = "## Notes\n\n" + n
    block = f"{MARK_START}\n\n{n}\n\n{MARK_END}"
    doc, k = re.subn(rf"{re.escape(MARK_START)}.*?{re.escape(MARK_END)}", lambda _: block, doc, flags=re.S)
    if k == 0:
        sys.exit("note has no LECTURE-NOTES markers")
    doc = re.sub(r"^notes_status: .*$", f"notes_status: done ({args.engine})", doc, count=1, flags=re.M)
    with open(args.note, "w", encoding="utf-8") as fh:
        fh.write(doc)
    print(f"  ✔ notes written ({len(n.split())} words)")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prompt")
    p.add_argument("note")
    p.add_argument("--out", required=True)
    p.add_argument("--tag-out")
    p.add_argument("--slides", action="append", default=[])
    p.add_argument("--no-slides", action="store_true")
    p.set_defaults(fn=cmd_prompt)
    m = sub.add_parser("merge")
    m.add_argument("note")
    m.add_argument("--generated", required=True)
    m.add_argument("--engine", default="cmd")
    m.set_defaults(fn=cmd_merge)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
