#!/usr/bin/env python3
"""Study notes from a local GGUF model, fully offline.

Runs llama-server on a loopback port for the duration of the job, does a
map-reduce over the transcript (chunk -> per-chunk notes -> synthesis), and
writes the result back into the note between the LECTURE-NOTES markers.
Prompts are chosen by the note's `language:` (el or en).
"""
import argparse
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
import urllib.request

CHUNK_WORDS = 3500

PROMPTS = {
    "el": {
        "rules": ("Γράψε στα ελληνικά. Κράτησε ΑΥΤΟΥΣΙΟΥΣ στα αγγλικά τους τεχνικούς όρους, "
                  "ονόματα βιβλιοθηκών, εντολές και ακρωνύμια. Μην εφευρίσκεις τίποτα που δεν "
                  "λέγεται στο κείμενο. Το κείμενο είναι αυτόματη απομαγνητοφώνηση και μπορεί να "
                  "έχει λάθη. Διόρθωσε προφανή λάθη αναγνώρισης σε γνωστούς όρους."),
        "map": """Είσαι βοηθός μελέτης. Παρακάτω είναι ΜΕΡΟΣ {i} από {n} της απομαγνητοφώνησης μιας πανεπιστημιακής διάλεξης ({course}).

{rules}

Δώσε συνοπτικά:
- τα θέματα που καλύπτονται, με τη χρονοσφραγίδα όπου ξεκινά το καθένα
- ορισμούς και τεχνικούς όρους που εισάγονται
- τύπους, αλγορίθμους ή παραδείγματα
- οτιδήποτε ακούγεται σαν ανακοίνωση, εργασία, προθεσμία ή "θα πέσει στις εξετάσεις"

ΚΕΙΜΕΝΟ:
{chunk}""",
        "reduce": """Έχεις τις σημειώσεις ανά τμήμα μιας διάλεξης ({course}, {date}). Συνένωσέ τες σε ΕΝΑ καθαρό σημείωμα μελέτης.

{rules}

Χρησιμοποίησε ΑΚΡΙΒΩΣ αυτή τη δομή σε Markdown, παραλείποντας όποια ενότητα δεν έχει περιεχόμενο:

### Σύνοψη
3-5 bullets: τι δίδαξε πραγματικά η διάλεξη.

### Δομή διάλεξης
Λίστα με χρονοσφραγίδες: `- **[HH:MM:SS]** θέμα`

### Βασικές έννοιες
`- **όρος**: ορισμός σε μία πρόταση`

### Τύποι & αλγόριθμοι

### Παραδείγματα που λύθηκαν

### Ανακοινώσεις & προθεσμίες
Εργασίες, ημερομηνίες, ύλη εξετάσεων. Γράψε "Καμία" αν δεν αναφέρθηκε τίποτα.

### Πιθανές ερωτήσεις εξέτασης
3-6 ερωτήσεις που απαντώνται από το υλικό.

ΣΗΜΕΙΩΣΕΙΣ ΑΝΑ ΤΜΗΜΑ:
{notes}""",
        "heading": "## Σημειώσεις",
    },
    "en": {
        "rules": ("Keep technical terms, library names, commands and acronyms exactly as they "
                  "are. Do not invent anything the text does not say. The text is an automatic "
                  "transcript and may contain errors. Fix obvious recognition errors in known terms."),
        "map": """You are a study assistant. Below is PART {i} of {n} of the transcript of a university lecture ({course}).

{rules}

Give, briefly:
- the topics covered, with the timestamp where each starts
- definitions and technical terms introduced
- formulas, algorithms or examples
- anything that sounds like an announcement, assignment, deadline or "this will be on the exam"

TEXT:
{chunk}""",
        "reduce": """You have per-part notes of one lecture ({course}, {date}). Merge them into ONE clean study note.

{rules}

Use EXACTLY this Markdown structure, dropping any section without content:

### Summary
3-5 bullets: what the lecture actually taught.

### Outline
Timestamped list: `- **[HH:MM:SS]** topic`

### Key concepts
`- **term**: one-sentence definition`

### Formulas and algorithms

### Worked examples

### Announcements and deadlines
Assignments, dates, exam scope. Write "None" if nothing was mentioned.

### Likely exam questions
3-6 questions answerable from the material.

PER-PART NOTES:
{notes}""",
        "heading": "## Notes",
    },
}


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Server:
    def __init__(self, model, port, ctx, threads):
        self.port, self.proc = port, None
        self.cmd = ["llama-server", "-m", model, "--port", str(port),
                    "--host", "127.0.0.1", "-c", str(ctx), "-ngl", "999",
                    "-fa", "on", "--no-webui", "-t", str(threads)]

    def __enter__(self):
        self.proc = subprocess.Popen(self.cmd, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, start_new_session=True)
        url = f"http://127.0.0.1:{self.port}/health"
        for _ in range(600):
            if self.proc.poll() is not None:
                raise RuntimeError("llama-server exited during startup")
            try:
                if urllib.request.urlopen(url, timeout=2).status == 200:
                    return self
            except Exception:
                time.sleep(1)
        raise RuntimeError("llama-server did not become healthy in time")

    def __exit__(self, *a):
        if self.proc and self.proc.poll() is None:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
            try:
                self.proc.wait(20)
            except subprocess.TimeoutExpired:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)

    def ask(self, prompt, max_tokens=1600):
        body = json.dumps({
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.2, "top_p": 0.9, "max_tokens": max_tokens,
        }).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/v1/chat/completions",
                                     data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=1800) as r:
            return json.load(r)["choices"][0]["message"]["content"].strip()


def chunks(text, size):
    paras, cur, n, out = text.split("\n\n"), [], 0, []
    for p in paras:
        w = len(p.split())
        if n + w > size and cur:
            out.append("\n\n".join(cur))
            cur, n = [], 0
        cur.append(p)
        n += w
    if cur:
        out.append("\n\n".join(cur))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("note")
    ap.add_argument("--model", default=os.environ.get("LECTURE_LLM", ""))
    ap.add_argument("--ctx", type=int, default=int(os.environ.get("LECTURE_LLM_CTX", "16384")))
    ap.add_argument("--threads", type=int, default=int(os.environ.get("LECTURE_THREADS", "8")))
    a = ap.parse_args()

    model = os.path.expanduser(a.model)
    if not model or not os.path.exists(model):
        sys.exit(f"LLM model not found: {model or '(unset)'}")

    with open(a.note, encoding="utf-8") as fh:
        doc = fh.read()
    if "<!-- LECTURE-NOTES-START -->" not in doc:
        sys.exit("note has no LECTURE-NOTES markers")
    if "notes_status: done" in doc:
        print("  notes already generated, skipping")
        return

    fm = dict(re.findall(r"^(course|date|language):\s*(.+)$", doc, re.M))
    course, date = fm.get("course", "?"), fm.get("date", "?")
    lang = fm.get("language", "en").split("-")[0]
    P = PROMPTS.get(lang, PROMPTS["en"])

    body = doc.split("## Transcript", 1)[1] if "## Transcript" in doc else doc
    transcript = re.sub(r"\*\*\[(\d\d:\d\d:\d\d)\]\*\*", r"[\1]", body).strip()
    if len(transcript.split()) < 120:
        print("  transcript too short for notes, skipping")
        return

    parts = chunks(transcript, CHUNK_WORDS)
    print(f"  LLM: {len(parts)} chunk(s) over {len(transcript.split())} words")

    with Server(model, free_port(), a.ctx, a.threads) as srv:
        per = []
        for i, c in enumerate(parts, 1):
            print(f"    chunk {i}/{len(parts)}…", flush=True)
            per.append(srv.ask(P["map"].format(i=i, n=len(parts), course=course,
                                               rules=P["rules"], chunk=c)))
        joined = per[0] if len(per) == 1 else "\n\n---\n\n".join(per)
        print("    synthesising…", flush=True)
        notes = srv.ask(P["reduce"].format(course=course, date=date,
                                           rules=P["rules"], notes=joined), max_tokens=2500)

    notes = re.sub(r"^```(?:markdown)?\s*|\s*```$", "", notes.strip())
    block = ("<!-- LECTURE-NOTES-START -->\n\n" + P["heading"] + "\n\n" + notes +
             "\n\n<!-- LECTURE-NOTES-END -->")
    doc = re.sub(r"<!-- LECTURE-NOTES-START -->.*?<!-- LECTURE-NOTES-END -->",
                 lambda _: block, doc, flags=re.S)
    doc = re.sub(r"^notes_status: .*$", "notes_status: done (local)", doc, count=1, flags=re.M)
    with open(a.note, "w", encoding="utf-8") as fh:
        fh.write(doc)
    print("  ✔ notes written")


if __name__ == "__main__":
    main()
