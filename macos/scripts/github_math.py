#!/usr/bin/env python3
r"""Checks and fixes LaTeX math in Markdown so that it renders on GitHub.

GitHub turns valid LaTeX into rendering errors in several ways:

- It applies Markdown backslash escapes inside $...$ and $$...$$ before MathJax
  runs: \!, \,, \;, \{ and \% lose their backslash, and \\[4pt] becomes \[4pt]
  ("Extra \left or missing \right").
- `_` emphasis can pair across two inline formulas, so neither renders.
- A ```math block inside a list stays plain code when the list has inline math.
- A math line that ends in a backslash gets a stray backslash appended.
- Some macros are rejected ("The following macros are not allowed: operatorname").

The forms that survive are a ```math block at the top level, $...$ with no
backslash before punctuation, and $`...`$, which GitHub passes on verbatim.
Display math inside a list is written as its own paragraph of $`\displaystyle ...`$.

  python3 scripts/github_math.py check [FILE.md ...]   report problems; exit 1 if any
  python3 scripts/github_math.py fix [FILE.md ...]     rewrite into those forms, then check

With no files, every tracked Markdown file of the macOS project is processed.
Unless --offline is given, each file with math is sent to GitHub's Markdown API
to confirm that every formula reaches MathJax exactly as written. The API is
called with GH_TOKEN, GITHUB_TOKEN or `gh auth token` when available, and
unauthenticated (60 requests per hour) otherwise.
"""

from __future__ import annotations
import argparse
import functools
import html
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
FENCE = re.compile(r"([ \t]*)(`{3,}|~{3,})(.*)")
# A backslash before ASCII punctuation is a Markdown escape, which GitHub removes from $...$ math.
MARKDOWN_ESCAPE = re.compile(r"\\[!-/:-@\[-`{-~]")
# Macros GitHub's math renderer rejects, with the replacement `fix` writes.
DISALLOWED_MACROS = {"operatorname": "mathrm"}
DISALLOWED = re.compile(r"\\(" + "|".join(DISALLOWED_MACROS) + r")\*?(?![A-Za-z])")


@dataclass
class Math:
    kind: str  # "fence" (```math), "block" ($$ starting a line), "display" ($$ in text), "tick" ($`...`$), "inline"
    body: str
    line: int  # 1-based line of the opening delimiter
    indent: str = ""  # fence and block only; non-empty inside a list item


@dataclass
class Problem:
    line: int
    message: str


def parse(text: str) -> list[str | Math]:
    """Splits Markdown into math and the text around it; non-math code is left as text."""
    lines = text.split("\n")
    starts = [0]
    for line in lines:
        starts.append(starts[-1] + len(line) + 1)
    pieces: list[str | Math] = []
    plain_start = i = 0
    while i < len(lines):
        fence = FENCE.fullmatch(lines[i])
        dollars = re.match(r"([ \t]*)\$\$(.*)", lines[i])
        one_line = dollars is not None and dollars.group(2).rstrip().endswith("$$")
        if fence:
            indent, marker, info = fence.groups()
            close = re.compile(rf"[ \t]*{re.escape(marker[0])}{{{len(marker)},}}[ \t]*")
            j = next((k for k in range(i + 1, len(lines)) if close.fullmatch(lines[k])), len(lines) - 1)
            raw = text[starts[i]:starts[j] + len(lines[j])]
            pieces += scan_inline(text, plain_start, starts[i])
            if info.strip() == "math":
                body = "\n".join(dedent(l, indent) for l in lines[i + 1:j])
                pieces.append(Math("fence", body, i + 1, indent))
            else:
                pieces.append(raw)
        elif dollars and (one_line or "$$" not in dollars.group(2)):
            indent = dollars.group(1)
            j = i if one_line else next((k for k in range(i + 1, len(lines)) if lines[k].rstrip().endswith("$$")), None)
            if j is None:
                i += 1
                continue
            raw = text[starts[i]:starts[j] + len(lines[j])]
            body = "\n".join(dedent(l, indent) for l in raw.strip()[2:-2].split("\n"))
            pieces += scan_inline(text, plain_start, starts[i])
            pieces.append(Math("block", body, i + 1, indent))
        else:
            i += 1
            continue
        plain_start = starts[j] + len(lines[j])
        i = j + 1
    return pieces + scan_inline(text, plain_start, len(text))


def dedent(line: str, indent: str) -> str:
    return line[len(indent):] if line.startswith(indent) else line.lstrip()


def scan_inline(text: str, start: int, end: int) -> list[str | Math]:
    pieces: list[str | Math] = []
    plain = pos = start
    line_of = lambda offset: text.count("\n", 0, offset) + 1
    while pos < end:
        if text[pos] == "\\":
            pos += 2
            continue
        if text.startswith("$`", pos):
            close, kind, body_start, after = text.find("`$", pos + 2, end), "tick", pos + 2, 2
        elif text[pos] == "`":
            ticks = re.match(r"`+", text[pos:end]).group(0)
            close = text.find(ticks, pos + len(ticks), end)
            pos = close + len(ticks) if close >= 0 else pos + len(ticks)
            continue
        elif text.startswith("$$", pos):
            close, kind, body_start, after = text.find("$$", pos + 2, end), "display", pos + 2, 2
        elif text[pos] == "$":
            line_end = text.find("\n", pos, end)
            close = text.find("$", pos + 1, end if line_end < 0 else line_end)
            kind, body_start, after = "inline", pos + 1, 1
        else:
            pos += 1
            continue
        if close < 0:
            pos += after
            continue
        pieces += [text[plain:pos], Math(kind, text[body_start:close], line_of(pos))]
        pos = plain = close + after
    pieces.append(text[plain:end])
    return [p for p in pieces if p != ""]


def fix_body(body: str) -> str:
    body = DISALLOWED.sub(lambda m: "\\" + DISALLOWED_MACROS[m.group(1)], body)
    # GitHub appends a backslash to a math line that ends in one, so start the next line with the row break instead.
    return re.sub(r"[ \t]*\\\\[ \t]*\n([ \t]*)", lambda m: "\n" + m.group(1) + "\\\\ ", body)


def fix_math(math: Math, force: set[str]) -> tuple[str, bool]:
    """Returns the math in a form GitHub renders as written, and whether it needs blank lines around it."""
    body = fix_body(math.body)
    if math.kind in ("fence", "block") and not math.indent:
        return "```math\n" + body.strip("\n") + "\n```", False
    if math.kind in ("fence", "block"):
        lines = [l.strip() for l in body.strip().split("\n")]
        lines[0] = "$`\\displaystyle " + lines[0]
        lines[-1] += "`$"
        return "\n".join(math.indent + l for l in lines), True
    if math.kind == "display":
        return "$`\\displaystyle " + body.strip() + "`$", False
    if math.kind == "tick" or MARKDOWN_ESCAPE.search(body) or body in force:
        return "$`" + body + "`$", False
    return "$" + body + "$", False


def fix_text(text: str, force: set[str]) -> str:
    out, blank_after = "", False
    pieces = parse(text)
    for n, piece in enumerate(pieces):
        source, blank_around = fix_math(piece, force) if isinstance(piece, Math) else (piece, False)
        if blank_after and not (re.match(r"\n[ \t]*\n", source) or (n == len(pieces) - 1 and not source.strip())):
            source = "\n" + source
        if blank_around and out and not re.search(r"\n[ \t]*\n$", out):
            out += "\n"
        out += source
        blank_after = blank_around
    return out


def static_problems(math: Math) -> list[Problem]:
    problems = []
    for macro in sorted(set(DISALLOWED.findall(math.body))):
        problems.append(Problem(math.line, f"GitHub does not allow \\{macro}; use \\{DISALLOWED_MACROS[macro]}"))
    if math.kind in ("block", "display"):
        problems.append(Problem(math.line, "$$...$$ loses its backslash escapes on GitHub; use a ```math block, "
                                           "or $`\\displaystyle ...`$ inside a list"))
    if math.kind == "fence" and math.indent:
        problems.append(Problem(math.line, "a ```math block inside a list shows as code on GitHub when the list has "
                                           "inline math; use $`\\displaystyle ...`$"))
    if math.kind == "inline":
        escapes = sorted(set(MARKDOWN_ESCAPE.findall(math.body)))
        if escapes:
            lose = "loses its" if len(escapes) == 1 else "lose their"
            problems.append(Problem(math.line, f"{' '.join(escapes)} {lose} backslash on GitHub; write $`...`$"))
    if re.search(r"\\[ \t]*\n", math.body):
        problems.append(Problem(math.line, "GitHub appends a backslash to a math line that ends in one; "
                                           "start the next line with the row break \\\\ instead"))
    if len(re.findall(r"\\left(?![A-Za-z])", math.body)) != len(re.findall(r"\\right(?![A-Za-z])", math.body)):
        problems.append(Problem(math.line, "unbalanced \\left / \\right"))
    return problems


@functools.lru_cache(maxsize=None)
def github_token() -> str | None:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token and shutil.which("gh"):
        result = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True)
        token = result.stdout.strip() if result.returncode == 0 else None
    return token


def render(text: str) -> str:
    request = urllib.request.Request(
        "https://api.github.com/markdown",
        data=json.dumps({"text": text, "mode": "gfm"}).encode("utf-8"),
        headers={"Accept": "application/vnd.github+json", "Content-Type": "application/json"},
    )
    if github_token():
        request.add_header("Authorization", f"Bearer {github_token()}")
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8")


def render_problems(text: str, maths: list[Math]) -> list[tuple[Problem, Math]]:
    """Formulas that do not reach GitHub's MathJax exactly as written."""
    normalize = lambda s: " ".join(s.split())
    got: Counter[str] = Counter()
    for span in re.findall(r"<math-renderer[^>]*>(.*?)</math-renderer>", render(text), re.S):
        # The API escapes <, > and & in math twice; the page undoes the second level before MathJax runs.
        span = html.unescape(html.unescape(span)).strip()
        got[normalize(span[2:-2] if span.startswith("$$") else span[1:-1])] += 1
    failed = []
    for math in maths:
        key = normalize(math.body)
        if got[key] > 0:
            got[key] -= 1
        else:
            shown = key if len(key) <= 70 else key[:67] + "..."
            failed.append((Problem(math.line, f"GitHub changes this formula before rendering it: {shown}"), math))
    return failed


def problems_in(text: str, offline: bool, rendered: list[tuple[Problem, Math]] | None = None) -> list[Problem]:
    maths = [p for p in parse(text) if isinstance(p, Math)]
    problems = [problem for math in maths for problem in static_problems(math)]
    if not offline:
        problems += [problem for problem, _ in (rendered if rendered is not None else render_problems(text, maths))]
    return sorted(problems, key=lambda p: p.line)


def fix(text: str, offline: bool) -> tuple[str, list[Problem]]:
    force: set[str] = set()
    for _ in range(3):
        fixed = fix_text(text, force)
        if offline:
            return fixed, problems_in(fixed, offline)
        rendered = render_problems(fixed, [p for p in parse(fixed) if isinstance(p, Math)])
        # Inline formulas GitHub still mangles (usually `_` emphasis pairing across two of them) get $`...`$ too.
        unrendered = {math.body for _, math in rendered if math.kind == "inline"}
        if not unrendered - force:
            break
        force |= unrendered
    return fixed, problems_in(fixed, offline, rendered)


def default_files() -> list[Path]:
    listed = subprocess.run(["git", "-C", str(PROJECT_ROOT), "ls-files", "-z", "*.md"],
                            capture_output=True, text=True, check=True).stdout
    return [PROJECT_ROOT / name for name in listed.split("\0") if name]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["check", "fix"])
    parser.add_argument("files", nargs="*", type=Path)
    parser.add_argument("--offline", action="store_true", help="skip the GitHub Markdown API round trip")
    args = parser.parse_intermixed_args()

    files = args.files or default_files()
    total = changed = 0
    errors: list[str] = []
    for path in files:
        text = path.read_text(encoding="utf-8")
        if "$" not in text:
            continue
        if args.command == "fix":
            fixed, problems = fix(text, args.offline)
            if fixed != text:
                path.write_text(fixed, encoding="utf-8")
                changed += 1
                print(f"🔧 Rewrote math in {path}")
            text = fixed
        else:
            problems = problems_in(text, args.offline)
        total += sum(isinstance(p, Math) for p in parse(text))
        errors += [f"{path}:{p.line}: {p.message}" for p in problems]

    if errors:
        for err in errors:
            print(f"❌ {err}", file=sys.stderr)
        return 1
    how = "statically (offline)" if args.offline else "against GitHub's renderer"
    noun = "file" if len(files) == 1 else "files"
    print(f"✅ Checked {total} formulas in {len(files)} Markdown {noun} {how}" + (f"; rewrote {changed}" if changed else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
