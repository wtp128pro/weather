#!/usr/bin/env python3
"""
Creates the Weather DMG installer background image.

Output: background.png (560 × 400 px) in the same directory as this script.

Run this script whenever you need to regenerate the background:
    python3 scripts/dmg_assets/create_background.py
"""

import math
import os
import struct
import zlib

WIDTH  = 560
HEIGHT = 400


# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------

def lerp(a: float, b: float, t: float) -> int:
    """
    Linearly interpolate between a and b at position t in [0, 1].

    Pre-conditions:
        a, b are numeric; t is in [0, 1].
    Returns:
        Clamped integer in [0, 255].
    """
    return max(0, min(255, int(a + (b - a) * t)))


def smoothstep(t: float) -> float:
    """
    Smooth-step curve: 0 → 1 with zero first derivatives at endpoints.

    Pre-conditions:
        t is any real number (clamped internally to [0, 1]).
    Returns:
        Float in [0.0, 1.0].
    """
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


# ---------------------------------------------------------------------------
# Background gradient (Sound-wave-glow concept)
# ---------------------------------------------------------------------------

def bilinear_gradient_color(tx: float, ty: float) -> tuple:
    """
    Compute the base background color at normalized position (tx, ty) via
    bilinear interpolation of four corner colors.

    Pre-conditions:
        tx, ty are floats in [0, 1] (pixel x/y normalized to image size).
    Parameters:
        tx: normalized horizontal position (0 = left edge, 1 = right edge).
        ty: normalized vertical position (0 = top edge, 1 = bottom edge).
    Returns:
        (r, g, b) integer tuple for the base gradient at this position.
    """
    TL = (14, 12, 34)   # top-left     – warm-leaning deep navy
    TR = (20, 16, 50)   # top-right    – warm-leaning midnight blue
    BL = (26, 10, 46)   # bottom-left  – warm-leaning dark indigo
    BR = (46, 14, 60)   # bottom-right – warm-leaning deep violet

    top_r = lerp(TL[0], TR[0], tx)
    top_g = lerp(TL[1], TR[1], tx)
    top_b = lerp(TL[2], TR[2], tx)
    bot_r = lerp(BL[0], BR[0], tx)
    bot_g = lerp(BL[1], BR[1], tx)
    bot_b = lerp(BL[2], BR[2], tx)
    return (
        lerp(top_r, bot_r, ty),
        lerp(top_g, bot_g, ty),
        lerp(top_b, bot_b, ty),
    )


# Concentric ripple sources: (cx, cy, base_radius, ring_count, ring_gap,
# ring_width, (r, g, b), max_alpha).
SOUND_SOURCES = [
    ( 60,  55, 30, 4, 26, 10, (225, 180, 100), 0.62),  # top-left ripple
    (500, 350, 34, 5, 30, 12, (225, 180, 100), 0.64),  # bottom-right ripple
    (500,  60, 20, 3, 22,  8, (255, 225, 150), 0.50),  # top-right ripple
    ( 60, 345, 22, 3, 24,  8, (255, 225, 150), 0.56),  # bottom-left ripple
    (283, 195, 46, 3, 40, 10, (255, 225, 150), 0.60),  # midpoint pulse, behind arrow
]


def sound_wave_glow(x: int, y: int) -> list:
    """
    Determine every warm-gold ring-glow blend contribution covering
    pixel (x, y).
    """
    hits = []
    for cx, cy, base_r, ring_count, gap, width, color, max_a in SOUND_SOURCES:
        dist = math.hypot(x - cx, y - cy)
        for k in range(ring_count):
            d = abs(dist - (base_r + k * gap))
            if d < width:
                falloff = 1.0 - 0.12 * (k / ring_count)
                alpha = smoothstep(1.0 - d / width) * max_a * falloff
                hits.append((color[0], color[1], color[2], alpha))
    return hits


# ---------------------------------------------------------------------------
# Arrow (warm gold gradient)
# ---------------------------------------------------------------------------

# App icon centre: x=155 → right edge at 155+64=219
# Applications centre: x=415 → left edge at 415-64=351
# Arrow fills the gap between the two icons.
ARROW_Y      = 195
SHAFT_X0     = 226   # shaft start (~7 px clear of app icon right edge)
SHAFT_X1     = 334   # shaft end (just before arrowhead base)
SHAFT_HALF_H = 3     # half-height of the shaft in pixels (3 px → 7 px thick)
TIP_X        = 350   # tip of the arrowhead (~1 px clear of Applications left edge)
ARROW_ALPHA  = 0.85  # brightness – clearly legible gold

_ARROW_BRONZE     = (150, 100, 46)   # dark shadow-gold
_ARROW_CREAM_GOLD = (255, 225, 150)  # bright highlight-gold


def arrow_gold_overlay(x: int, y: int):
    """
    Determine the warm-gold arrow overlay at pixel (x, y), if any.
    """
    span = TIP_X - SHAFT_X0
    t = max(0.0, min(1.0, (x - SHAFT_X0) / span))
    r = lerp(_ARROW_BRONZE[0], _ARROW_CREAM_GOLD[0], t)
    g = lerp(_ARROW_BRONZE[1], _ARROW_CREAM_GOLD[1], t)
    b = lerp(_ARROW_BRONZE[2], _ARROW_CREAM_GOLD[2], t)

    if SHAFT_X0 <= x <= SHAFT_X1 and abs(y - ARROW_Y) <= SHAFT_HALF_H:
        fade = smoothstep((x - SHAFT_X0) / max(1, SHAFT_X1 - SHAFT_X0))
        return (r, g, b, ARROW_ALPHA * fade)

    if SHAFT_X1 < x <= TIP_X:
        progress = (x - SHAFT_X1) / (TIP_X - SHAFT_X1)   # 0 at base, 1 at tip
        half_h = int((1.0 - progress) * 12)               # tapers to 0 at tip
        if abs(y - ARROW_Y) <= half_h:
            return (r, g, b, ARROW_ALPHA * smoothstep(1.0 - progress))

    return None


# ---------------------------------------------------------------------------
# Pixel generation
# ---------------------------------------------------------------------------

def build_pixel_rows() -> list:
    """
    Build the full image as a list of raw RGB byte-rows.
    """
    rows = []
    for y in range(HEIGHT):
        ty = y / (HEIGHT - 1)
        row = bytearray()

        for x in range(WIDTH):
            tx = x / (WIDTH - 1)
            r, g, b = bilinear_gradient_color(tx, ty)

            for gr, gg, gb, ga in sound_wave_glow(x, y):
                r = min(255, r + int((gr - r) * ga))
                g = min(255, g + int((gg - g) * ga))
                b = min(255, b + int((gb - b) * ga))

            overlay = arrow_gold_overlay(x, y)
            if overlay is not None:
                or_, og_, ob_, a = overlay
                r = min(255, r + int((or_ - r) * a))
                g = min(255, g + int((og_ - g) * a))
                b = min(255, b + int((ob_ - b) * a))

            row += bytes([r, g, b])

        rows.append(bytes(row))
    return rows


# ---------------------------------------------------------------------------
# Minimal PNG writer (stdlib only — no Pillow required)
# ---------------------------------------------------------------------------

def write_png(path: str, width: int, height: int, rows: list) -> None:
    """
    Write a 24-bit RGB PNG using only Python's standard library.
    """
    def chunk(tag: bytes, data: bytes) -> bytes:
        """Pack a PNG chunk: length + tag + data + CRC32."""
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)

    # PNG magic bytes
    signature = b'\x89PNG\r\n\x1a\n'

    # IHDR: width(4) height(4) bit-depth(1) colour-type-2=RGB(1) compress(1) filter(1) interlace(1)
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))

    # IDAT: prepend filter-byte 0 (None) to each row, compress everything together
    raw_scanlines = b''.join(b'\x00' + row for row in rows)
    idat = chunk(b'IDAT', zlib.compress(raw_scanlines, 9))

    iend = chunk(b'IEND', b'')

    with open(path, 'wb') as f:
        f.write(signature + ihdr + idat + iend)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    here = os.path.dirname(os.path.abspath(__file__))
    out  = os.path.join(here, 'background.png')
    print(f'Generating {WIDTH}×{HEIGHT} background → {out}')
    rows = build_pixel_rows()
    write_png(out, WIDTH, HEIGHT, rows)
    print('Done.')
