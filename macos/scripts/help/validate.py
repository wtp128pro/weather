#!/usr/bin/env python3
"""Validates the NeginatoMezora.help bundle structure, TOC, links, and search index."""

from __future__ import annotations
import json
import re
import sys
from _helplib import CONTENTS_DIR, EN_LPROJ, all_pages


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
        if page["title"] not in html_text:
            errors.append(f"Page {page['href']} does not contain its title '{page['title']}'")
        for href in re.findall(r'href="([^"#]+)"', html_text):
            if href.startswith(("http://", "https://")):
                continue
            if not (EN_LPROJ / href).is_file():
                errors.append(f"Broken relative link '{href}' in {page['href']}")

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

    if errors:
        for err in errors:
            print(f"❌ {err}", file=sys.stderr)
        return 1

    print(f"✅ Validated {len(pages)} help pages, assets, links, and search index in {EN_LPROJ}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
