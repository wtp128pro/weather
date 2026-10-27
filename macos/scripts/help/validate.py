#!/usr/bin/env python3
"""Validates the NeginatoMezora.help bundle structure, TOC, links, search index, and that regenerate.py made it."""

from __future__ import annotations
import html
import json
import re
import sys
from _helplib import CONTENTS_DIR, EN_LPROJ, REPO_ROOT, all_pages
from regenerate import bundle_files


def main() -> int:
    errors: list[str] = []

    info_plist = CONTENTS_DIR / "Info.plist"
    if not info_plist.is_file():
        errors.append(f"Missing {info_plist}")

    for asset in ["book.css", "help-ui.css", "help.js", "search-index.js", "toc.json", "_shell.html"]:
        path = EN_LPROJ / asset
        if not path.is_file():
            errors.append(f"Missing required asset: {path}")

    pages = all_pages()
    known_hrefs = {p["href"] for p in pages}

    for page in pages:
        page_path = EN_LPROJ / page["href"]
        if not page_path.is_file():
            errors.append(f"Missing help page: {page_path}")
            continue
        html_text = page_path.read_text(encoding="utf-8")
        # The page's own <title>, as render_shell writes it: every page's nav lists every title.
        if f"<title>{html.escape(page['title'])} — Neginato Mezora Help</title>" not in html_text:
            errors.append(f"Page {page['href']} does not contain its title '{page['title']}'")
        for href in re.findall(r'href="([^"]+)"', html_text):
            if href.startswith(("http://", "https://")):
                continue
            target, _, anchor = href.partition("#")
            target_path = EN_LPROJ / target if target else page_path
            if not target_path.is_file():
                errors.append(f"Broken relative link '{href}' in {page['href']}")
            elif anchor and f'id="{anchor}"' not in target_path.read_text(encoding="utf-8"):
                errors.append(f"Missing anchor '#{anchor}' for link '{href}' in {page['href']}")
        if "<!-- WEIGHT_TABLES -->" in html_text:
            errors.append(f"Unfilled weight tables in {page['href']}")

    # Every page the app opens (HelpWindowManager.shared.showHelp(page:)) must exist.
    for swift in (REPO_ROOT / "Weather").rglob("*.swift"):
        for call in re.findall(r"showHelp\(page:([^)]*)\)", swift.read_text(encoding="utf-8")):
            for target in re.findall(r'"([^"]+)"', call):
                if target not in known_hrefs:
                    errors.append(f"{swift.relative_to(REPO_ROOT)} opens help page '{target}', which is not in the book")

    search_js_path = EN_LPROJ / "search-index.js"
    if search_js_path.is_file():
        raw = search_js_path.read_text(encoding="utf-8")
        prefix = "window.HELP_SEARCH_INDEX = "
        if not raw.startswith(prefix):
            errors.append("search-index.js missing window.HELP_SEARCH_INDEX prefix")
        else:
            payload = raw[len(prefix):].rstrip().rstrip(";")
            entries = json.loads(payload)
            indexed_hrefs = {e["href"] for e in entries}
            if indexed_hrefs != known_hrefs:
                errors.append(f"Search index href mismatch: {indexed_hrefs} vs {known_hrefs}")

    # A hand edit of the bundle, or a pages.py / weight_tables.html edit without a regenerate run, is lost or unshipped.
    # Bytes, not text: read_text's universal newlines would pass a file whose only change is CRLF line endings.
    for path, text in bundle_files().items():
        if not path.is_file() or path.read_bytes() != text.encode("utf-8"):
            errors.append(f"Stale {path.relative_to(REPO_ROOT)}: it is not what regenerate.py writes (run it)")

    if errors:
        for err in errors:
            print(f"❌ {err}", file=sys.stderr)
        return 1

    print(f"✅ Validated {len(pages)} help pages, assets, links, and search index in {EN_LPROJ}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
