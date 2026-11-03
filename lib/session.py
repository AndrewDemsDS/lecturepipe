"""Session kind and number from a file stem: lp_session in common.sh, in Python.

A token is one of the words below, not glued to a letter on either side, with an
optional "-", "_" or space and a 1 to 2 digit number. The first token in the stem
decides the kind; the number is the first one written after a token of that kind.
No token means a lecture, so older names keep filing as before.
"""
import re

KINDS = {
    "lecture": ("lecture", "lec", "dialexi"),
    "lab": ("lab", "ergastirio"),
    "recitation": ("recitation", "frontistirio"),
}
DIRS = {"lecture": "lectures", "lab": "labs", "recitation": "recitations"}
_KIND_OF = {t: k for k, ts in KINDS.items() for t in ts}
TOKEN = re.compile(r"(?<![^\W\d_])(" + "|".join(sorted(_KIND_OF, key=len, reverse=True))
                   + r")(?:[-_ ]?(\d{1,2}))?(?![^\W\d_])", re.I)


def parse(stem):
    """(kind, number or None) for a file stem."""
    kind, num = None, None
    for m in TOKEN.finditer(stem):
        k = _KIND_OF[m.group(1).lower()]
        kind = kind or k
        if k == kind and m.group(2):
            num = int(m.group(2))
            break
    return kind or "lecture", num
