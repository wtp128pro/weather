#!/usr/bin/env python3
"""
Creates the Neginato Mezora DMG installer background image.

Theme: Meteorological sky backdrop featuring:
  - Atmospheric daytime-to-storm-front sky gradient (cerulean azure to deep slate navy)
  - Radiant golden sun with sunbeams peeking behind a volumetric cumulus cloud (top-left)
  - Rain-bearing nimbus cloud with angled cyan/cobalt raindrop streaks (top-right)
  - Sweeping synoptic isobar / wind-streamline contours across the sky
  - Subtle sub-hourly precipitation nowcast bar & probability curve motif along the bottom horizon
  - Soft atmospheric glow behind the Neginato Mezora.app (x=155, y=195) and Applications (x=415, y=195) drop zones
  - Crisp sky-cyan to solar-gold directional install arrow between the two icon drop zones

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

# Icon centres (must match write_ds_store.py)
APP_ICON_X,  APP_ICON_Y  = 155.0, 195.0
APPS_ICON_X, APPS_ICON_Y = 415.0, 195.0


# ---------------------------------------------------------------------------
# Colour & math helpers
# ---------------------------------------------------------------------------

def clamp_byte(v: float) -> int:
    return max(0, min(255, int(round(v))))


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def smoothstep(t: float) -> float:
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


def blend_rgb(base: tuple, over_rgb: tuple, alpha: float) -> tuple:
    """Alpha-composite over_rgb onto base (r, g, b) with alpha in [0, 1]."""
    if alpha <= 0.0:
        return base
    a = min(1.0, alpha)
    return (
        lerp(base[0], over_rgb[0], a),
        lerp(base[1], over_rgb[1], a),
        lerp(base[2], over_rgb[2], a),
    )


def dist_to_segment(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
    """Euclidean distance from point (px, py) to line segment (ax, ay)-(bx, by)."""
    pax, pay = px - ax, py - ay
    bax, bay = bx - ax, by - ay
    denom = bax * bax + bay * bay
    h = 0.0 if denom == 0.0 else max(0.0, min(1.0, (pax * bax + pay * bay) / denom))
    return math.hypot(pax - bax * h, pay - bay * h)


def sd_capsule(px: float, py: float, ax: float, ay: float, bx: float, by: float, r: float) -> float:
    """Signed distance from (px, py) to a line capsule (ax, ay)-(bx, by) of radius r."""
    return dist_to_segment(px, py, ax, ay, bx, by) - r


# ---------------------------------------------------------------------------
# 1. Atmospheric Sky Gradient
# ---------------------------------------------------------------------------

def sky_gradient_color(tx: float, ty: float) -> tuple:
    """
    Compute the base meteorological sky color at normalized position (tx, ty).
    Transitions from sunlit cerulean azure in the upper-left to deep storm-slate
    navy in the upper-right and twilight horizon indigo along the bottom.
    """
    TL = (34.0,  96.0, 174.0)   # top-left     – sunlit cerulean sky
    TR = (18.0,  46.0,  92.0)   # top-right    – rain-front storm slate
    BL = (20.0,  58.0, 112.0)   # bottom-left  – horizon steel blue
    BR = (12.0,  30.0,  64.0)   # bottom-right – deep oceanic troposphere

    top_r = lerp(TL[0], TR[0], tx)
    top_g = lerp(TL[1], TR[1], tx)
    top_b = lerp(TL[2], TR[2], tx)
    bot_r = lerp(BL[0], BR[0], tx)
    bot_g = lerp(BL[1], BR[1], tx)
    bot_b = lerp(BL[2], BR[2], tx)

    # Slight horizon glow around ty = 0.52
    horizon = math.exp(-((ty - 0.52) / 0.28) ** 2) * 0.14
    r = lerp(top_r, bot_r, ty) + 18.0 * horizon * (1.0 - 0.4 * tx)
    g = lerp(top_g, bot_g, ty) + 34.0 * horizon
    b = lerp(top_b, bot_b, ty) + 52.0 * horizon
    return (r, g, b)


# ---------------------------------------------------------------------------
# 2. Radiant Golden Sun & Sunbeams (Top-Left Sky)
# ---------------------------------------------------------------------------

SUN_CX, SUN_CY = 74.0, 62.0
SUN_RADIUS     = 26.0


def apply_sun_and_rays(rgb: tuple, x: float, y: float) -> tuple:
    dx, dy = x - SUN_CX, y - SUN_CY
    dist = math.hypot(dx, dy)

    # Broad warm atmospheric solar corona
    if dist < 175.0:
        corona_t = 1.0 - dist / 175.0
        corona_a = (corona_t ** 2.4) * 0.38
        rgb = blend_rgb(rgb, (255.0, 198.0, 72.0), corona_a)

    # Distinct sunbeams (8 rays matching the Neginato Mezora app icon)
    if 31.0 <= dist <= 50.0:
        angle = math.atan2(dy, dx)
        sector = round(angle / (math.pi / 4.0)) * (math.pi / 4.0)
        perp = abs(math.sin(angle - sector)) * dist
        radial_edge = min(dist - 31.0, 50.0 - dist)
        if perp < 4.2 and radial_edge > 0.0:
            ray_a = smoothstep(1.0 - perp / 4.2) * smoothstep(min(1.0, radial_edge / 3.5)) * 0.92
            rgb = blend_rgb(rgb, (253.0, 202.0, 56.0), ray_a)

    # Sun disc with warm amber-to-gold vertical gradient
    if dist < SUN_RADIUS + 1.5:
        disc_a = smoothstep(SUN_RADIUS + 1.2 - dist)
        vt = max(0.0, min(1.0, (y - (SUN_CY - SUN_RADIUS)) / (2.0 * SUN_RADIUS)))
        sun_col = (
            lerp(255.0, 245.0, vt),
            lerp(215.0, 158.0, vt),
            lerp(64.0,   14.0, vt),
        )
        rgb = blend_rgb(rgb, sun_col, disc_a)

    return rgb


# ---------------------------------------------------------------------------
# 3. Sculpted Volumetric Weather Clouds
# ---------------------------------------------------------------------------

def cloud_sdf(x: float, y: float, puffs: list, base_y: float, left_x: float, right_x: float) -> float:
    """
    Signed distance to a flat-bottomed multi-puff cumulus cloud.
    Negative inside the cloud, positive outside.
    """
    d = 1e9
    for cx, cy, r in puffs:
        d = min(d, math.hypot(x - cx, y - cy) - r)
    # Fill the lower interior bridge between left_x and right_x up to base_y
    if left_x <= x <= right_x and y <= base_y:
        top_bridge = base_y - 22.0
        if y >= top_bridge:
            d = min(d, max(top_bridge - y, y - base_y))
    # Flatten bottom below base_y
    if y > base_y:
        d = max(d, y - base_y)
    return d


# Top-left cumulus cloud (peeking in front of the sun, matching weather.svg)
CLOUD_TL_PUFFS = [
    ( 76.0, 86.0, 19.0),
    ( 98.0, 74.0, 25.0),
    (124.0, 80.0, 21.0),
    (142.0, 89.0, 15.0),
    ( 60.0, 91.0, 14.0),
]
CLOUD_TL_BASE_Y = 102.0

# Top-right rain-bearing nimbus cloud
CLOUD_TR_PUFFS = [
    (426.0, 68.0, 17.0),
    (448.0, 56.0, 24.0),
    (476.0, 52.0, 27.0),
    (504.0, 62.0, 21.0),
    (524.0, 70.0, 15.0),
]
CLOUD_TR_BASE_Y = 82.0


def apply_clouds(rgb: tuple, x: float, y: float) -> tuple:
    # 1) Top-left sunlit cumulus cloud (fully opaque body so sun stays behind it)
    if 36.0 <= x <= 166.0 and 40.0 <= y <= 114.0:
        d_shadow = cloud_sdf(x - 2.0, y - 4.0, CLOUD_TL_PUFFS, CLOUD_TL_BASE_Y, 60.0, 142.0)
        if d_shadow < 6.0:
            sh_a = smoothstep(1.0 - max(0.0, d_shadow) / 6.0) * 0.24
            rgb = blend_rgb(rgb, (10.0, 28.0, 58.0), sh_a)

        d = cloud_sdf(x, y, CLOUD_TL_PUFFS, CLOUD_TL_BASE_Y, 60.0, 142.0)
        if d < 1.5:
            cov = smoothstep(1.2 - d)
            vt = max(0.0, min(1.0, (y - 50.0) / (CLOUD_TL_BASE_Y - 50.0)))
            col = (
                lerp(248.0, 214.0, vt),
                lerp(252.0, 231.0, vt),
                lerp(255.0, 250.0, vt),
            )
            rgb = blend_rgb(rgb, col, cov)

    # 2) Top-right rain-bearing nimbus cloud (storm-silver tint)
    if 400.0 <= x <= 548.0 and 20.0 <= y <= 94.0:
        d_shadow = cloud_sdf(x - 2.0, y - 4.0, CLOUD_TR_PUFFS, CLOUD_TR_BASE_Y, 426.0, 524.0)
        if d_shadow < 6.0:
            sh_a = smoothstep(1.0 - max(0.0, d_shadow) / 6.0) * 0.26
            rgb = blend_rgb(rgb, (8.0, 20.0, 44.0), sh_a)

        d = cloud_sdf(x, y, CLOUD_TR_PUFFS, CLOUD_TR_BASE_Y, 426.0, 524.0)
        if d < 1.5:
            cov = smoothstep(1.2 - d)
            vt = max(0.0, min(1.0, (y - 26.0) / (CLOUD_TR_BASE_Y - 26.0)))
            col = (
                lerp(228.0, 166.0, vt),
                lerp(240.0, 190.0, vt),
                lerp(252.0, 222.0, vt),
            )
            rgb = blend_rgb(rgb, col, cov)

    return rgb


# ---------------------------------------------------------------------------
# 4. Falling Raindrop Streaks (Top-Right under Nimbus Cloud)
# ---------------------------------------------------------------------------

# Raindrop capsules tilted slightly (-9 deg like weather.svg): (x0, y0, x1, y1, radius, alpha)
RAINDROPS = [
    (434.0,  92.0, 429.0, 114.0, 2.6, 0.85),
    (454.0,  98.0, 448.0, 124.0, 2.8, 0.90),
    (475.0,  90.0, 470.0, 112.0, 2.6, 0.85),
    (495.0,  96.0, 489.0, 122.0, 2.8, 0.90),
    (515.0,  91.0, 510.0, 113.0, 2.5, 0.82),
    # Second staggered tier of raindrops
    (498.0, 132.0, 493.0, 152.0, 2.3, 0.68),
    (520.0, 126.0, 515.0, 148.0, 2.4, 0.74),
    (536.0, 104.0, 531.0, 126.0, 2.4, 0.72),
]


def apply_raindrops(rgb: tuple, x: float, y: float) -> tuple:
    if x < 420.0 or y < 86.0 or y > 160.0:
        return rgb
    for ax, ay, bx, by, r, max_a in RAINDROPS:
        d = sd_capsule(x, y, ax, ay, bx, by, r)
        if d < 1.5:
            cov = smoothstep(1.2 - d) * max_a
            t = max(0.0, min(1.0, (y - ay) / max(1.0, by - ay)))
            drop_col = (
                lerp(96.0,  28.0, t),
                lerp(212.0, 136.0, t),
                lerp(255.0, 248.0, t),
            )
            rgb = blend_rgb(rgb, drop_col, cov)
    return rgb


# ---------------------------------------------------------------------------
# 5. Synoptic Isobars / Wind Streamlines & Bottom Nowcast Rain Chart Motif
# ---------------------------------------------------------------------------

def apply_isobars_and_nowcast(rgb: tuple, x: float, y: float) -> tuple:
    tx = x / (WIDTH - 1)

    # Gentle atmospheric wind/isobar streamlines across upper & lower sky
    iso1_y = 66.0 + 18.0 * math.sin(tx * math.pi * 2.2 - 0.4)
    d1 = abs(y - iso1_y)
    if d1 < 1.8 and 175.0 <= x <= 395.0:
        fade_ends = smoothstep((x - 175.0) / 35.0) * smoothstep((395.0 - x) / 35.0)
        a1 = smoothstep(1.8 - d1) * 0.18 * fade_ends
        rgb = blend_rgb(rgb, (170.0, 222.0, 255.0), a1)

    iso2_y = 316.0 + 12.0 * math.sin(tx * math.pi * 2.6 + 0.7)
    d2 = abs(y - iso2_y)
    if d2 < 1.8:
        a2 = smoothstep(1.8 - d2) * 0.16
        rgb = blend_rgb(rgb, (140.0, 208.0, 255.0), a2)

    # Bottom Horizon Nowcast Rain Bars + Probability Curve (y in 325..392)
    # Echoes Neginato Mezora's signature dual-series Rain Rate Bars & Chance Curve
    if y >= 325.0:
        curve_y = (
            368.0
            - 22.0 * math.exp(-((tx - 0.28) / 0.16) ** 2)
            - 28.0 * math.exp(-((tx - 0.72) / 0.18) ** 2)
        )
        if y > curve_y:
            fill_t = max(0.0, min(1.0, (y - curve_y) / (HEIGHT - curve_y)))
            rgb = blend_rgb(rgb, (56.0, 189.0, 248.0), (1.0 - fill_t) * 0.10)

        dc = abs(y - curve_y)
        if dc < 2.2:
            ca = smoothstep(2.2 - dc) * 0.48
            rgb = blend_rgb(rgb, (251.0, 191.0, 36.0), ca)

        y_base = 392.0
        slot_w = 14.0
        bar_half_w = 3.6
        slot_idx = int(x // slot_w)
        slot_cx = (slot_idx + 0.5) * slot_w
        stx = slot_cx / WIDTH
        bar_h = (
            34.0 * math.exp(-((stx - 0.28) / 0.13) ** 2)
            + 42.0 * math.exp(-((stx - 0.72) / 0.14) ** 2)
        )
        if bar_h >= 4.0 and y <= y_base:
            top_y = y_base - bar_h
            dx_bar = abs(x - slot_cx)
            if dx_bar <= bar_half_w + 1.0 and y >= top_y - 1.0:
                if y < top_y + bar_half_w:
                    d_bar = math.hypot(dx_bar, (top_y + bar_half_w) - y) - bar_half_w
                else:
                    d_bar = dx_bar - bar_half_w
                if d_bar < 1.0:
                    ba = smoothstep(1.0 - d_bar) * 0.42
                    bt = max(0.0, min(1.0, (y_base - y) / max(1.0, bar_h)))
                    bar_col = (
                        lerp(18.0,  86.0, bt),
                        lerp(118.0, 214.0, bt),
                        lerp(232.0, 255.0, bt),
                    )
                    rgb = blend_rgb(rgb, bar_col, ba)

    return rgb


# ---------------------------------------------------------------------------
# 6. Icon Drop-Zone Atmospheric Glow & Directional Install Arrow
# ---------------------------------------------------------------------------

ARROW_Y      = 195.0
SHAFT_X0     = 228.0
SHAFT_X1     = 332.0
SHAFT_HALF_H = 3.2
HEAD_HALF_H  = 12.5
TIP_X        = 349.0


def apply_drop_zone_halos(rgb: tuple, x: float, y: float) -> tuple:
    """Soft borderless radial glow behind the two icon drop zones."""
    for cx, cy in ((APP_ICON_X, APP_ICON_Y), (APPS_ICON_X, APPS_ICON_Y)):
        dist = math.hypot(x - cx, y - cy)
        if dist < 82.0:
            halo_t = 1.0 - dist / 82.0
            rgb = blend_rgb(rgb, (165.0, 218.0, 255.0), (halo_t ** 2.2) * 0.15)
    return rgb


def arrow_signed_distance(x: float, y: float) -> float:
    """
    Exact signed distance to the horizontal arrow (shaft rectangle + triangular head).
    """
    dy = abs(y - ARROW_Y)

    # Check if inside shaft rectangle
    in_shaft = (SHAFT_X0 <= x <= SHAFT_X1) and (dy <= SHAFT_HALF_H)
    # Check if inside triangular arrowhead
    in_head = False
    if SHAFT_X1 <= x <= TIP_X:
        allowed_h = (1.0 - (x - SHAFT_X1) / (TIP_X - SHAFT_X1)) * HEAD_HALF_H
        if dy <= allowed_h:
            in_head = True

    # Distance to boundary segments in upper half-plane (x, dy)
    d1 = dist_to_segment(x, dy, SHAFT_X0, 0.0, SHAFT_X0, SHAFT_HALF_H)
    d2 = dist_to_segment(x, dy, SHAFT_X0, SHAFT_HALF_H, SHAFT_X1, SHAFT_HALF_H)
    d3 = dist_to_segment(x, dy, SHAFT_X1, SHAFT_HALF_H, SHAFT_X1, HEAD_HALF_H)
    d4 = dist_to_segment(x, dy, SHAFT_X1, HEAD_HALF_H, TIP_X, 0.0)
    dist_edge = min(d1, d2, d3, d4)

    return -dist_edge if (in_shaft or in_head) else dist_edge


def apply_arrow(rgb: tuple, x: float, y: float) -> tuple:
    if x < SHAFT_X0 - 10.0 or x > TIP_X + 10.0 or abs(y - ARROW_Y) > HEAD_HALF_H + 10.0:
        return rgb

    d = arrow_signed_distance(x, y)
    span = TIP_X - SHAFT_X0
    t = max(0.0, min(1.0, (x - SHAFT_X0) / span))
    fade_in = smoothstep(min(1.0, max(0.0, (x - SHAFT_X0 + 4.0) / 24.0)))

    # Soft outer sky-cyan glow around the arrow
    if 0.0 < d < 6.5:
        glow_a = smoothstep(1.0 - d / 6.5) * 0.28 * fade_in
        rgb = blend_rgb(rgb, (72.0, 202.0, 255.0), glow_a)

    # Crisp arrow body: sky-cyan on the left transitioning to warm solar gold at the tip
    if d < 1.2:
        body_a = smoothstep(1.0 - d) * 0.94 * fade_in
        arrow_col = (
            lerp(110.0, 255.0, t),
            lerp(218.0, 214.0, t),
            lerp(255.0, 102.0, t),
        )
        rgb = blend_rgb(rgb, arrow_col, body_a)

    return rgb


# ---------------------------------------------------------------------------
# Pixel generation
# ---------------------------------------------------------------------------

def build_pixel_rows() -> list:
    """Build the full 560×400 image as a list of raw RGB byte-rows."""
    rows = []
    for y in range(HEIGHT):
        ty = y / (HEIGHT - 1)
        fy = float(y)
        row = bytearray()

        for x in range(WIDTH):
            tx = x / (WIDTH - 1)
            fx = float(x)

            rgb = sky_gradient_color(tx, ty)
            rgb = apply_sun_and_rays(rgb, fx, fy)
            rgb = apply_clouds(rgb, fx, fy)
            rgb = apply_raindrops(rgb, fx, fy)
            rgb = apply_isobars_and_nowcast(rgb, fx, fy)
            rgb = apply_drop_zone_halos(rgb, fx, fy)
            rgb = apply_arrow(rgb, fx, fy)

            row += bytes((
                clamp_byte(rgb[0]),
                clamp_byte(rgb[1]),
                clamp_byte(rgb[2]),
            ))

        rows.append(bytes(row))
    return rows


# ---------------------------------------------------------------------------
# Minimal PNG writer (stdlib only — no Pillow required)
# ---------------------------------------------------------------------------

def write_png(path: str, width: int, height: int, rows: list) -> None:
    """Write a 24-bit RGB PNG using only Python's standard library."""
    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)

    signature = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    raw_scanlines = b''.join(b'\x00' + row for row in rows)
    idat = chunk(b'IDAT', zlib.compress(raw_scanlines, 9))
    iend = chunk(b'IEND', b'')

    with open(path, 'wb') as f:
        f.write(signature + ihdr + idat + iend)


if __name__ == '__main__':
    here = os.path.dirname(os.path.abspath(__file__))
    out  = os.path.join(here, 'background.png')
    print(f'Generating {WIDTH}×{HEIGHT} weather DMG background → {out}')
    rows = build_pixel_rows()
    write_png(out, WIDTH, HEIGHT, rows)
    print('Done.')
