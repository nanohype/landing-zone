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

HEREDOCS

`#` inside a heredoc is data, not a comment — a policy document or an embedded
script carries hashes that mean something. The scan tracks heredoc bodies and
leaves them alone, so a gate reading a resource does not lose an attribute
because the value above it embedded a shell comment.

WHAT IT DOES NOT DO

It does not give a view for reading comments. A gate whose vocabulary IS a
comment — a waiver, an annotation — must read those from the raw text. The two
views answer different questions and one call cannot serve both; a gate needing
both reads the raw text for its annotations and the blanked text for the code
they annotate.
"""

from __future__ import annotations

import re

_HEREDOC = re.compile(r"<<[-~]?(?P<tag>[A-Za-z_][A-Za-z0-9_]*)[ \t]*\r?\n")


def _terminator(text: str, start: int, tag: str) -> int:
    """Offset just past the line that closes this heredoc, or end of text.

    A heredoc with no terminator is malformed HCL that OpenTofu rejects outright;
    consuming to the end keeps the scan from treating the remainder as code and
    reporting on a document that does not parse anyway.
    """
    for m in re.finditer(rf"^[ \t]*{re.escape(tag)}[ \t]*$", text[start:], re.M):
        return start + m.end()
    return len(text)


def blank_comments(text: str) -> str:
    """Blank every HCL comment interior, preserving length and line breaks.

    Length and line breaks are preserved so a byte offset into the result maps
    to the same line in the file — a gate reporting a line number after
    stripping would otherwise cite a line that drifted by the number of
    comments above it.

    The scan carries a CONTEXT STACK rather than a single in-string flag,
    because HCL nests the two states inside each other. A template
    interpolation opens a fresh expression context INSIDE a string, and that
    expression can contain its own strings:

        arn = "${var.prefix}${var.env == "prod" ? "/*" : "/staging"}"

    Counting every quote as a delimiter inverts the string/code polarity at the
    first nested quote. With an odd number of them the scan believes it is in
    code where it is in a string, and the `/*` above then opens a block comment
    that runs to end of file — the rest of the document is blanked and every
    gate reading it sees a nearly empty tree while reporting a pass.
    """
    out: list[str] = []
    # Each frame is (kind, brace_depth). kind is "code" or "str".
    stack: list[list] = [["code", 0]]
    i = 0
    n = len(text)

    while i < n:
        c = text[i]
        kind = stack[-1][0]

        if kind == "str":
            if c == "\\" and i + 1 < n:
                out.append(text[i : i + 2])
                i += 2
                continue
            # `$${` and `%%{` are escaped literals, not interpolation openers.
            if text.startswith("$${", i) or text.startswith("%%{", i):
                out.append(text[i : i + 3])
                i += 3
                continue
            if text.startswith("${", i) or text.startswith("%{", i):
                stack.append(["code", 0])
                out.append(text[i : i + 2])
                i += 2
                continue
            if c == '"':
                stack.pop()
                out.append(c)
                i += 1
                continue
            out.append(c)
            i += 1
            continue

        # kind == "code": top level, or inside an interpolation.
        if c == '"':
            stack.append(["str", 0])
            out.append(c)
            i += 1
            continue
        if c == "{":
            stack[-1][1] += 1
            out.append(c)
            i += 1
            continue
        if c == "}":
            if stack[-1][1] > 0:
                stack[-1][1] -= 1
            elif len(stack) > 1:
                # Closes the interpolation; the enclosing string resumes.
                stack.pop()
            out.append(c)
            i += 1
            continue
        if text.startswith("<<", i):
            # A heredoc body is data. Copy it through verbatim to its
            # terminator so an embedded `#` — a shell comment in a user-data
            # script, a comment inside a policy document — is not read as an
            # HCL comment.
            m = _HEREDOC.match(text, i)
            if m:
                end = _terminator(text, m.end(), m.group("tag"))
                out.append(text[i:end])
                i = end
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
