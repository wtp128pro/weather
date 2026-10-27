#!/usr/bin/env python3
"""Regenerates the bundled NeginatoMezora.help HTML Help Book and search index."""

from __future__ import annotations
import json
from pathlib import Path
import html
from _helplib import CONTENTS_DIR, EN_LPROJ, SECTIONS, all_pages, strip_html
from pages import PAGE_BODIES, WEIGHT_TABLES, WEIGHT_TABLES_MARKER

INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.wtp128pro.Weather.help</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Neginato Mezora Help</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.4.0</string>
    <key>CFBundleSignature</key>
    <string>hbwr</string>
    <key>CFBundleVersion</key>
    <string>4</string>
    <key>HPDBookAccessPath</key>
    <string>index.html</string>
    <key>HPDBookTitle</key>
    <string>Neginato Mezora Help</string>
    <key>HPDBookType</key>
    <string>3</string>
</dict>
</plist>
"""

BOOK_CSS = """
:root {
    color-scheme: dark;
    --bg: #0f172a;
    --sidebar-bg: #111c33;
    --card-bg: #1e293b;
    --border: rgba(255, 255, 255, 0.12);
    --text: #f8fafc;
    --muted: #94a3b8;
    --accent: #38bdf8;
    --amber: #fb923c;
}
* { box-sizing: border-box; }
body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.6;
}
.help-layout {
    display: grid;
    grid-template-columns: 260px 1fr;
    min-height: 100vh;
}
.help-sidebar {
    background: var(--sidebar-bg);
    border-right: 1px solid var(--border);
    padding: 18px 14px;
    position: sticky;
    top: 0;
    height: 100vh;
    overflow-y: auto;
}
.brand {
    font-size: 15px;
    font-weight: 700;
    color: var(--text);
    margin-bottom: 12px;
    display: flex;
    align-items: center;
    gap: 8px;
}
.search-input {
    width: 100%;
    padding: 7px 10px;
    border-radius: 7px;
    border: 1px solid var(--border);
    background: rgba(15, 23, 42, 0.75);
    color: var(--text);
    font-size: 13px;
    margin-bottom: 14px;
}
.nav-section {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--muted);
    margin: 14px 6px 6px;
}
.nav-link {
    display: block;
    padding: 6px 10px;
    border-radius: 6px;
    color: var(--text);
    text-decoration: none;
    font-size: 13px;
    margin-bottom: 2px;
}
.nav-link:hover { background: rgba(56, 189, 248, 0.12); }
.nav-link.active {
    background: rgba(56, 189, 248, 0.22);
    color: var(--accent);
    font-weight: 600;
}
.help-main {
    padding: 32px 44px 64px;
    max-width: 880px;
}
h1 { font-size: 26px; margin-top: 0; letter-spacing: -0.01em; }
h2 { font-size: 19px; margin-top: 28px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }
h3 { font-size: 15px; margin-top: 20px; color: var(--accent); }
p, li { font-size: 14px; color: #e2e8f0; }
code, pre {
    font-family: "SF Mono", Menlo, monospace;
    background: rgba(15, 23, 42, 0.75);
    border: 1px solid var(--border);
    border-radius: 5px;
}
code { padding: 1px 5px; font-size: 12.5px; }
pre { padding: 12px 14px; overflow-x: auto; font-size: 12.5px; }
table {
    width: 100%;
    border-collapse: collapse;
    margin: 14px 0 20px;
    font-size: 13px;
    background: var(--card-bg);
    border-radius: 8px;
    overflow: hidden;
}
th, td {
    padding: 8px 11px;
    border-bottom: 1px solid var(--border);
    text-align: left;
}
th { background: rgba(255, 255, 255, 0.05); color: var(--accent); font-weight: 600; }
.callout {
    background: var(--card-bg);
    border-left: 3px solid var(--accent);
    padding: 12px 16px;
    border-radius: 6px;
    margin: 16px 0;
}
.callout.amber { border-left-color: var(--amber); }
.search-results {
    margin-bottom: 14px;
    display: none;
}
.search-results.visible { display: block; }
.search-hit {
    display: block;
    padding: 7px 9px;
    border-radius: 6px;
    background: var(--card-bg);
    margin-bottom: 6px;
    text-decoration: none;
    color: var(--text);
    font-size: 12.5px;
    border: 1px solid var(--border);
}
.search-hit strong { color: var(--accent); display: block; }
a { color: var(--accent); }
kbd {
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    font-size: 12px;
    padding: 1px 6px;
    border: 1px solid var(--border);
    border-bottom-width: 2px;
    border-radius: 5px;
    background: rgba(255, 255, 255, 0.06);
    white-space: nowrap;
}
details {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 8px 12px;
    margin: 10px 0;
}
details > summary { cursor: pointer; font-size: 14px; }
details table { background: transparent; }
td code { white-space: nowrap; }
"""

HELP_JS = """
(function() {
    const input = document.getElementById('help-search');
    const resultsBox = document.getElementById('search-results');
    if (!input || !resultsBox || !window.HELP_SEARCH_INDEX) return;

    input.addEventListener('input', function() {
        const q = input.value.trim().toLowerCase();
        resultsBox.replaceChildren();
        if (q.length < 2) {
            resultsBox.classList.remove('visible');
            return;
        }
        const hits = window.HELP_SEARCH_INDEX.filter(item =>
            item.title.toLowerCase().includes(q) || item.body.toLowerCase().includes(q)
        );
        if (hits.length === 0) {
            const none = document.createElement('div');
            none.className = 'search-hit';
            none.textContent = 'No matching topics found.';
            resultsBox.appendChild(none);
        } else {
            hits.forEach(hit => {
                const a = document.createElement('a');
                a.className = 'search-hit';
                a.href = hit.href;
                const title = document.createElement('strong');
                title.textContent = hit.title;
                const section = document.createElement('span');
                section.textContent = hit.section;
                a.append(title, section);
                resultsBox.appendChild(a);
            });
        }
        resultsBox.classList.add('visible');
    });
})();
"""


def render_shell(current_id: str, title: str, body_html: str) -> str:
    nav_parts: list[str] = []
    for section in SECTIONS:
        nav_parts.append(f'<div class="nav-section">{section["title"]}</div>')
        for page in section["pages"]:
            active = " active" if page["id"] == current_id else ""
            nav_parts.append(
                f'<a class="nav-link{active}" href="{page["href"]}">{html.escape(page["title"])}</a>'
            )
    nav_html = "\n".join(nav_parts)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="AppleTitle" content="Neginato Mezora Help">
    <title>{html.escape(title)} — Neginato Mezora Help</title>
    <link rel="stylesheet" href="book.css">
    <link rel="stylesheet" href="help-ui.css">
</head>
<body>
    <div class="help-layout">
        <aside class="help-sidebar">
            <div class="brand">⛅ Neginato Mezora Help</div>
            <input id="help-search" class="search-input" type="search" placeholder="Search documentation…">
            <div id="search-results" class="search-results"></div>
            <nav>
                {nav_html}
            </nav>
        </aside>
        <main class="help-main">
            {body_html.strip()}
        </main>
    </div>
    <script src="search-index.js"></script>
    <script src="help.js"></script>
</body>
</html>
"""


def bundle_files() -> dict[Path, str]:
    """Every file of the bundle and its contents; validate.py compares the bundle on disk with this."""
    files = {
        CONTENTS_DIR / "Info.plist": INFO_PLIST.strip() + "\n",
        EN_LPROJ / "book.css": BOOK_CSS.strip() + "\n",
        EN_LPROJ / "help-ui.css": "/* Additional UI overrides */\n",
        EN_LPROJ / "help.js": HELP_JS.strip() + "\n",
        EN_LPROJ / "toc.json": json.dumps({"sections": SECTIONS}, indent=2) + "\n",
        EN_LPROJ / "_shell.html": render_shell("__PAGE_ID__", "__PAGE_TITLE__", "__PAGE_BODY__"),
    }

    weight_tables = WEIGHT_TABLES.read_text(encoding="utf-8")
    search_index = []
    for page in all_pages():
        pid = page["id"]
        body = PAGE_BODIES[pid].replace(WEIGHT_TABLES_MARKER, weight_tables)
        files[EN_LPROJ / page["href"]] = render_shell(pid, page["title"], body)
        search_index.append(
            {
                "id": pid,
                "title": page["title"],
                "section": page["section"],
                "href": page["href"],
                "body": strip_html(body),
            }
        )

    files[EN_LPROJ / "search-index.js"] = "window.HELP_SEARCH_INDEX = " + json.dumps(search_index, indent=2) + ";\n"
    return files


def main() -> None:
    CONTENTS_DIR.mkdir(parents=True, exist_ok=True)
    EN_LPROJ.mkdir(parents=True, exist_ok=True)
    for path, text in bundle_files().items():
        path.write_text(text, encoding="utf-8")
    print(f"Regenerated {len(all_pages())} help pages in {EN_LPROJ}")


if __name__ == "__main__":
    main()
