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
            {"id": "places", "href": "places.html", "title": "Adding & Managing Places"},
            {"id": "forecast-page", "href": "forecast-page.html", "title": "Reading the Forecast"},
            {"id": "rain-chart", "href": "rain-chart.html", "title": "Rain Graph & Bars Guide"},
            {"id": "units-refresh", "href": "units-refresh.html", "title": "Units, Refreshing & Offline"},
            {"id": "shortcuts", "href": "shortcuts.html", "title": "Keyboard Shortcuts & Menus"},
        ],
    },
    {
        "id": "settings",
        "title": "Settings",
        "pages": [
            {"id": "sources-weights", "href": "sources-weights.html", "title": "Settings: Data Sources & Weights"},
            {"id": "stations-settings", "href": "stations-settings.html", "title": "Settings: Stations"},
            {"id": "station-keys", "href": "station-keys.html", "title": "Free Keys for More Stations"},
        ],
    },
    {
        "id": "how-it-works",
        "title": "How It Works",
        "pages": [
            {"id": "local-corrections", "href": "local-corrections.html", "title": "Learned Local Corrections"},
            {"id": "live-stations", "href": "live-stations.html", "title": "Live Station Observations"},
            {"id": "algorithms", "href": "algorithms.html", "title": "Ensemble Blending & Citations"},
        ],
    },
    {
        "id": "reference",
        "title": "Reference",
        "pages": [
            {"id": "privacy", "href": "privacy.html", "title": "Privacy, Data & Storage"},
            {"id": "troubleshooting", "href": "troubleshooting.html", "title": "Troubleshooting & FAQ"},
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
