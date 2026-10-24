#!/usr/bin/env python3
"""Shared utilities and page definitions for the Neginato Mezora Help Book."""

from __future__ import annotations
import html
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
HELP_BUNDLE = REPO_ROOT / "Weather" / "NeginatoMezora.help"
CONTENTS_DIR = HELP_BUNDLE / "Contents"
EN_LPROJ = CONTENTS_DIR / "Resources" / "en.lproj"

SECTIONS = [
    {
        "id": "getting-started",
        "title": "Getting Started",
        "pages": [
            {"id": "index", "href": "index.html", "title": "Welcome to Neginato Mezora"},
            {"id": "rain-chart", "href": "rain-chart.html", "title": "Rain Graph & Bars Guide"},
            {"id": "shortcuts", "href": "shortcuts.html", "title": "Keyboard Shortcuts & Places"},
        ],
    },
    {
        "id": "sources-and-weights",
        "title": "Sources & Ensemble Weights",
        "pages": [
            {"id": "sources-weights", "href": "sources-weights.html", "title": "Settings: Data Sources & Weights"},
        ],
    },
    {
        "id": "algorithms-and-physics",
        "title": "Algorithms & Meteorology",
        "pages": [
            {"id": "algorithms", "href": "algorithms.html", "title": "Ensemble Blending & Citations"},
            {"id": "live-stations", "href": "live-stations.html", "title": "Live Station 3D Assimilation"},
        ],
    },
]


def strip_html(raw_html: str) -> str:
    text = re.sub(r"<script\b[^>]*>.*?</script>", " ", raw_html, flags=re.DOTALL | re.IGNORECASE)
    text = re.sub(r"<style\b[^>]*>.*?</style>", " ", text, flags=re.DOTALL | re.IGNORECASE)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def all_pages() -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    for section in SECTIONS:
        for page in section["pages"]:
            out.append({**page, "section": section["title"]})
    return out
