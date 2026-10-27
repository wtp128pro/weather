#!/usr/bin/env python3
"""scan_tests.py [--root <WeatherCoreTests dir>] [--out <file>]

Mechanical test-health scan of a Swift Testing / XCTest tree (read-only).
Every *.swift file under --root is checked for each pattern class below; every
non-Swift file is treated as a bundle fixture (copied FLAT into the bundle, see
Support/TestSupport.swift `Fixtures`). Hits are CANDIDATES: each must be
confirmed by hand. Output: two header lines (the exact command; the counts),
then one tab-separated hit per line: kind, file:line, detail. Exit 0 after
writing.

Defaults: --root is ../../WeatherCoreTests relative to this script (the
repository's macos/WeatherCoreTests); --out is "-", standard output (the
one-line summary then goes to standard error).

Kinds:
  no-expectation  @Test / test* func whose body has no #expect/#require/XCTAssert/
                  Issue.record/confirmation/withKnownIssue and calls no asserting
                  helper (a test that only checks that a `try` does not throw is
                  still listed: confirm by hand)
  expectation-via-helper  (informational) test with no inline assertion that calls an asserting helper
  disabled        .disabled / .enabled(if:) / XCTSkip / withKnownIssue / commented-out @Test
  sleep           Task.sleep / sleep( / usleep / Thread.sleep / asyncAfter
  wall-clock      Date() / Date.now / CFAbsoluteTimeGetCurrent / DispatchTime.now / ProcessInfo uptime
  real-host       http(s):// literal not on 127.0.0.1/localhost/example.(com|org|net)/invalid, URLSession.shared
  shared-state    static var / nonisolated(unsafe) / UserDefaults.standard / fixed /tmp path / .serialized
  fixture-dup     two fixtures with the same basename (flat copy collides)
  fixture-unused  fixture whose basename and stem appear in no Swift file
"""
import argparse, os, re, shlex, sys
from collections import defaultdict

ASSERT = re.compile(r"#expect|#require|XCTAssert|XCTFail|Issue\.record|confirmation\(|withKnownIssue")
PATTERNS = [
    ("disabled", re.compile(r"\.disabled\b|\.enabled\(if:|XCTSkip|withKnownIssue|^\s*//\s*@Test")),
    ("sleep", re.compile(r"Task\.sleep|\busleep\(|(?<![\w.])sleep\(|Thread\.sleep|asyncAfter\(")),
    ("wall-clock", re.compile(r"\bDate\(\)|\bDate\.now\b|CFAbsoluteTimeGetCurrent|DispatchTime\.now|systemUptime")),
    ("real-host", re.compile(r"URLSession\.shared")),
    ("shared-state", re.compile(r"\bstatic\s+var\b|nonisolated\(unsafe\)|UserDefaults\.standard|\"/tmp/|\.serialized\b")),
]
URL_RE = re.compile(r"https?://([A-Za-z0-9.\-\[\]:]+)")
SAFE_HOST = re.compile(r"^(127\.0\.0\.1|localhost|\[::1\]|.*\.invalid|.*\.test|.*example\.(com|org|net))(:\d+)?$")
FUNC_RE = re.compile(r"\bfunc\s+(\w+)\s*(?:<[^>]*>)?\s*\(")
STR_RE = re.compile(r'"(?:\\.|[^"\\])*"')  # string literals are blanked before brace counting


def strip_comment(line):
    i = line.find("//")
    return line if i < 0 else line[:i]


def test_bodies(lines):
    """Yield (name, start_line, body_text) for @Test funcs and XCTest test* funcs."""
    pending = False
    for i, raw in enumerate(lines):
        code = strip_comment(raw)
        if re.search(r"@Test\b", code):
            pending = True
        m = FUNC_RE.search(code)
        if not m or not (pending or m.group(1).startswith("test")):
            continue
        pending = False
        depth, started, body = 0, False, []
        for j in range(i, len(lines)):
            c = strip_comment(lines[j])
            body.append(c)
            for ch in STR_RE.sub('""', c):
                if ch == "{":
                    depth += 1; started = True
                elif ch == "}":
                    depth -= 1
            if started and depth <= 0:
                break
        yield m.group(1), i + 1, "\n".join(body)


def all_funcs(lines):
    """Every func (helpers included): (name, line, body)."""
    for i, raw in enumerate(lines):
        m = FUNC_RE.search(strip_comment(raw))
        if not m:
            continue
        depth, started, body = 0, False, []
        for j in range(i, len(lines)):
            c = strip_comment(lines[j]); body.append(c)
            b = STR_RE.sub('""', c)
            depth += b.count("{") - b.count("}")
            started = started or "{" in c
            if started and depth <= 0:
                break
        yield m.group(1), i + 1, "\n".join(body)


def scan(root):
    hits, swift_text, fixtures, funcs, candidates = [], {}, [], {}, []
    for d, _, files in os.walk(root):
        for f in sorted(files):
            p = os.path.join(d, f)
            rel = os.path.relpath(p, os.path.dirname(root.rstrip("/")))
            if f.startswith("."):
                continue
            if not f.endswith(".swift"):
                fixtures.append((f, rel)); continue
            lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
            swift_text[rel] = "\n".join(lines)
            for n, raw in enumerate(lines, 1):
                for kind, rx in PATTERNS:
                    src = raw if kind == "disabled" else strip_comment(raw)
                    if rx.search(src):
                        hits.append((kind, f"{rel}:{n}", raw.strip()[:140]))
                for host in URL_RE.findall(strip_comment(raw)):
                    if not SAFE_HOST.match(host):
                        hits.append(("real-host", f"{rel}:{n}", raw.strip()[:140]))
            for name, ln, body in all_funcs(lines):
                funcs.setdefault(name, []).append((f"{rel}:{ln}", body))
            for name, ln, body in test_bodies(lines):
                if not ASSERT.search(body):
                    candidates.append((f"{rel}:{ln}", name, body))
    # A helper "asserts" if its body has an assertion or calls an asserting helper (fixpoint).
    asserting = {n for n, defs in funcs.items() if any(ASSERT.search(b) for _, b in defs)}
    while True:
        more = {n for n, defs in funcs.items() if n not in asserting
                and any(re.search(r"\b(" + "|".join(map(re.escape, asserting)) + r")\s*\(", b) for _, b in defs)} if asserting else set()
        if not more: break
        asserting |= more
    for loc, name, body in candidates:
        called = sorted(h for h in asserting if h != name and re.search(r"\b" + re.escape(h) + r"\s*\(", body))
        if called:
            hits.append(("expectation-via-helper", loc, f"func {name} -> {', '.join(called[:4])}"))
        else:
            hits.append(("no-expectation", loc, f"func {name}"))
    by_base = defaultdict(list)
    for base, rel in fixtures:
        by_base[base].append(rel)
    for base, rels in sorted(by_base.items()):
        if len(rels) > 1:
            hits.append(("fixture-dup", f"{rels[0]}:1", "same basename: " + ", ".join(rels)))
    alltext = "\n".join(swift_text.values())
    # Interpolated names ("stations-smhi-\(p).json") reference every fixture with that prefix.
    prefixes = [m for m in re.findall(r'"([\w.\-]{4,})\\\(', alltext)]
    for base, rel in sorted(fixtures):
        stem = os.path.splitext(base)[0]
        if base not in alltext and f'"{stem}"' not in alltext and not any(base.startswith(x) for x in prefixes):
            hits.append(("fixture-unused", f"{rel}:1", f"{base} not referenced by name or stem"))
    return hits, len(swift_text), len(fixtures)


DEFAULT_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                            "..", "..", "WeatherCoreTests"))


def main():
    ap = argparse.ArgumentParser(description="Mechanical test-health scan (read-only); hits are candidates.")
    ap.add_argument("--root", default=DEFAULT_ROOT,
                    help="test tree to scan (default: ../../WeatherCoreTests relative to this script)")
    ap.add_argument("--out", default="-", help="output file, or - for standard output (default: -)")
    a = ap.parse_args()
    if not os.path.isdir(a.root):
        sys.exit(f"--root {a.root} is not a directory")
    hits, nswift, nfix = scan(os.path.abspath(a.root))
    cmd = "python3 " + " ".join(shlex.quote(x) for x in [sys.argv[0]] + sys.argv[1:])
    o = sys.stdout if a.out == "-" else open(a.out, "w")
    try:
        o.write(f"# command: {cmd}\n# swift_files={nswift} fixtures={nfix} hits={len(hits)}\n")
        for h in hits:
            o.write("\t".join(h) + "\n")
    finally:
        if o is not sys.stdout:
            o.close()
    print(f"swift_files={nswift} fixtures={nfix} hits={len(hits)}", file=sys.stderr if a.out == "-" else sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
