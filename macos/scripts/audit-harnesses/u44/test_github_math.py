#!/usr/bin/env python3
"""U44 regression tests for scripts/github_math.py (U25-F1, U25-F6).

  python3 -I -B test_github_math.py [path/to/github_math.py]

The default script is $REPO/scripts/github_math.py, where REPO defaults to the macos/ directory three
levels above this file. Runs `fix --offline` on scratch files in a fresh temp dir (removed afterwards);
exit 0 = all pass, 1 = a case failed."""
import os, subprocess, sys, tempfile
from pathlib import Path

REPO = Path(os.environ.get("REPO") or Path(__file__).resolve().parents[3])
script = Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "scripts" / "github_math.py").resolve()
if not script.is_file():
    sys.exit(f"no such script: {script}")
failed = 0

def fix(name: str, text: str) -> tuple[int, str, str]:
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / f"{name}.md"
        f.write_text(text, encoding="utf-8")
        r = subprocess.run([sys.executable, "-I", "-B", str(script), "fix", "--offline", str(f)], capture_output=True, text=True)
        return r.returncode, f.read_text(encoding="utf-8"), (r.stdout + r.stderr).strip().splitlines()[-1:]

def case(name: str, text: str, want_exit: int, want: str) -> None:
    global failed
    code, out, tail = fix(name, text)
    ok = code == want_exit and out == want
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'} {name}: exit {code}, file {out!r}" + ("" if ok else f" (want exit {want_exit}, file {want!r}; tail {tail})"))

# U25-F1: an unterminated ```math fence at EOF without a trailing newline keeps its last line.
case("f1_math_unterminated", "Inline $a$.\n\n```math\nx^2\ny^2", 0, "Inline $a$.\n\n```math\nx^2\ny^2\n```")
# U25-F1 (verifier): an unterminated non-math fence is left alone, no IndexError.
case("f1_python_unterminated", "Inline $a$.\n\n```python\nprint(1)", 0, "Inline $a$.\n\n```python\nprint(1)")
# Controls that already worked: trailing newline, a closed fence.
case("f1_math_unterminated_nl", "Inline $a$.\n\n```math\nx^2\ny^2\n", 0, "Inline $a$.\n\n```math\nx^2\ny^2\n```")
case("f1_math_closed", "Inline $a$.\n\n```math\nx^2\ny^2\n```\n", 0, "Inline $a$.\n\n```math\nx^2\ny^2\n```\n")
# U25-F6: two display formulas with prose between them on one $$...$$ line stay two formulas.
case("f6_two_on_one_line", "Text\n\n$$a$$ and then prose $$b$$\n", 0,
     "Text\n\n$`\\displaystyle a`$ and then prose $`\\displaystyle b`$\n")
# Controls: a lone one-line $$...$$ and a multi-line $$ block still become ```math blocks.
case("f6_lone_one_line", "Text\n\n$$x^2$$\n", 0, "Text\n\n```math\nx^2\n```\n")
case("f6_multi_line", "Text\n\n$$\nx^2\n$$\n", 0, "Text\n\n```math\nx^2\n```\n")
print(f"{'OK' if not failed else 'FAILED'}: {failed} failed")
sys.exit(1 if failed else 0)
