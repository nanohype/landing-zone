"""Shared HCL text views for the gates under scripts/.

Not a gate: the filename is outside the `check-*` glob that `task gates`, CI and
the positive-control floor discover, so this file is imported and never run.

WHY A SHARED HELPER

A gate reading HCL needs the same view its consumer has. OpenTofu does not see
comments, so a gate that reads raw text can count a commented-out declaration as
present — a fail-open where the gate reports agreement between two sets that do
not agree. Every gate needing that view needs the same three cases handled
(`#`, `//`, `/* */`), and a per-gate copy is a place for one of them to be
missed.

WHY IT MUST BE QUOTE-AWARE

`/*` and `//` both occur inside ordinary HCL strings — `arn:aws:s3:::bucket/*`
and any `https://` URL. A stripper that scans for the tokens without tracking
string state deletes live policy from the middle of a resource, and the gate
then reports on a document the author never wrote. In this tree 23 files contain
`/*` only inside a string, against 3 that contain a real block comment, so the
naive reading is wrong far more often than it is right.

WHAT IT DOES NOT DO

It does not give a view for reading comments. A gate whose vocabulary IS a
comment — a waiver, an annotation — must read those from the raw text. The two
views answer different questions and one call cannot serve both; a gate needing
both reads the raw text for its annotations and the blanked text for the code
they annotate.
"""

from __future__ import annotations


def blank_comments(text: str) -> str:
    """Blank every HCL comment interior, preserving length and line breaks.

    Length and line breaks are preserved so a byte offset into the result maps
    to the same line in the file — a gate reporting a line number after
    stripping would otherwise cite a line that drifted by the number of
    comments above it.
    """
    out: list[str] = []
    quote: str | None = None
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if quote:
            if c == "\\" and i + 1 < n:
                out.append(text[i : i + 2])
                i += 2
                continue
            if c == quote:
                quote = None
            out.append(c)
            i += 1
            continue
        if c == '"':
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "#" or text.startswith("//", i):
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            for j in range(i, end):
                out.append("\n" if text[j] == "\n" else " ")
            i = end
            continue
        out.append(c)
        i += 1
    return "".join(out)
