#!/usr/bin/env python3
"""Generate embedded tray icons from Motif's app icon.

The tray icon is a small monochrome derivative of the foreground mark in the
macOS app icon. Stopped is an outlined mountain mark, active states are filled,
and error states add a monochrome exclamation mark. This intentionally avoids
Pillow so the generated file can be refreshed with a stock Python install.
"""

from __future__ import annotations

import base64
import math
import struct
import zlib
from pathlib import Path


# The menu bar scales a status item by HEIGHT, so we fix the canvas height at
# 18pt @2x and let the width follow the mark's aspect — this makes the glyph
# fill the bar instead of floating in the app icon's built-in padding (which
# left it looking tiny). `W` is recomputed from the mark's bounding box.
H = 36
W = 36  # placeholder; set by app_icon_mask() from the mark aspect
MARGIN = 2  # px of breathing room on each edge within the canvas
ROOT = Path(__file__).resolve().parents[1]
APP_ICON = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png"
OUT = ROOT / "lib/motif/platform/tray_icons.g.dart"

# Neutral gray keeps the icon visible on both light and dark menu bars.
INK = (150, 150, 150)


def clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def png(rgba: bytes | bytearray, w: int, h: int) -> bytes:
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += rgba[y * w * 4 : (y + 1) * w * 4]

    def chunk(typ: bytes, data: bytes) -> bytes:
        c = struct.pack(">I", len(data)) + typ + data
        return c + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    idat = zlib.compress(bytes(raw), 9)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def read_png(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")

    pos = 8
    width = height = bit_depth = color_type = None
    idat = bytearray()
    while pos < len(data):
        size = struct.unpack(">I", data[pos : pos + 4])[0]
        typ = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + size]
        pos += 12 + size
        if typ == b"IHDR":
            width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(
                ">IIBBBBB", body
            )
            if bit_depth != 8 or compression != 0 or filter_method != 0 or interlace != 0:
                raise ValueError("only non-interlaced 8-bit PNGs are supported")
            if color_type not in (2, 6):
                raise ValueError("only RGB/RGBA PNGs are supported")
        elif typ == b"IDAT":
            idat.extend(body)
        elif typ == b"IEND":
            break

    if width is None or height is None or color_type is None:
        raise ValueError(f"{path} is missing IHDR")

    channels = 4 if color_type == 6 else 3
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    rows: list[bytearray] = []
    i = 0
    prev = bytearray(stride)
    for _ in range(height):
        filter_type = raw[i]
        i += 1
        row = bytearray(raw[i : i + stride])
        i += stride
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            up = prev[x]
            up_left = prev[x - channels] if x >= channels else 0
            if filter_type == 1:
                row[x] = (row[x] + left) & 0xFF
            elif filter_type == 2:
                row[x] = (row[x] + up) & 0xFF
            elif filter_type == 3:
                row[x] = (row[x] + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                p = left + up - up_left
                pa = abs(p - left)
                pb = abs(p - up)
                pc = abs(p - up_left)
                predictor = left if pa <= pb and pa <= pc else up if pb <= pc else up_left
                row[x] = (row[x] + predictor) & 0xFF
            elif filter_type != 0:
                raise ValueError(f"unsupported PNG filter {filter_type}")
        rows.append(row)
        prev = row

    rgba = bytearray(width * height * 4)
    for y, row in enumerate(rows):
        for x in range(width):
            src = x * channels
            dst = (y * width + x) * 4
            rgba[dst] = row[src]
            rgba[dst + 1] = row[src + 1]
            rgba[dst + 2] = row[src + 2]
            rgba[dst + 3] = row[src + 3] if channels == 4 else 255
    return width, height, bytes(rgba)


def smoothstep(edge0: float, edge1: float, x: float) -> float:
    t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def mark_alpha(r: int, g: int, b: int, alpha: int) -> float:
    # Keep the white mountains and the cyan underline from the app icon, then
    # render both as one monochrome tray glyph.
    mountain = smoothstep(150.0, 220.0, float(min(r, g, b)))
    underline = smoothstep(110.0, 170.0, (float(g) + float(b)) / 2.0)
    underline *= 1.0 - smoothstep(120.0, 180.0, float(r))
    fg = max(mountain, underline)
    return fg * (alpha / 255.0)


def mark_bbox(
    src_w: int, src_h: int, rgba: bytes, thresh: float = 0.3
) -> tuple[int, int, int, int]:
    """Bounding box (in source pixels) of the foreground mark, so we can crop
    away the app icon's padding before scaling the glyph into the canvas."""
    minx, miny, maxx, maxy = src_w, src_h, -1, -1
    for y in range(src_h):
        row = y * src_w
        for x in range(src_w):
            i = (row + x) * 4
            if mark_alpha(rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]) >= thresh:
                minx, maxx = min(minx, x), max(maxx, x)
                miny, maxy = min(miny, y), max(maxy, y)
    if maxx < 0:
        raise ValueError("no foreground mark found in app icon")
    return minx, miny, maxx, maxy


def app_icon_mask(path: Path) -> list[float]:
    global W
    src_w, src_h, rgba = read_png(path)
    minx, miny, maxx, maxy = mark_bbox(src_w, src_h, rgba)
    mw, mh = maxx - minx + 1, maxy - miny + 1

    # Canvas fills the height; width follows the mark aspect. The glyph occupies
    # everything but a MARGIN border, so it renders at the full menu-bar height.
    gh = H - 2 * MARGIN
    W = int(round(gh * (mw / mh) + 2 * MARGIN))
    gw = W - 2 * MARGIN

    slack = 1.04  # tiny zoom-out so anti-aliased stroke edges aren't clipped
    cx = (minx + maxx + 1) / 2.0
    cy = (miny + maxy + 1) / 2.0
    span_x, span_y = mw * slack, mh * slack
    x0, y0 = cx - span_x / 2.0, cy - span_y / 2.0

    sample_grid = 8
    mask = [0.0] * (W * H)
    for oy in range(H):
        for ox in range(W):
            a = 0.0
            for sy in range(sample_grid):
                ny = (oy + (sy + 0.5) / sample_grid - MARGIN) / gh
                src_y = int(y0 + ny * span_y)
                if src_y < 0 or src_y >= src_h:
                    continue
                for sx in range(sample_grid):
                    nx = (ox + (sx + 0.5) / sample_grid - MARGIN) / gw
                    src_x = int(x0 + nx * span_x)
                    if src_x < 0 or src_x >= src_w:
                        continue
                    i = (src_y * src_w + src_x) * 4
                    a += mark_alpha(rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
            mask[oy * W + ox] = a / (sample_grid * sample_grid)
    return mask


def erode_mask(mask: list[float], radius: float) -> list[float]:
    r = math.ceil(radius)
    out = [0.0] * (W * H)
    for y in range(H):
        for x in range(W):
            m = 1.0
            for dy in range(-r, r + 1):
                for dx in range(-r, r + 1):
                    if math.hypot(dx, dy) > radius:
                        continue
                    nx, ny = x + dx, y + dy
                    if nx < 0 or nx >= W or ny < 0 or ny >= H:
                        m = 0.0
                    else:
                        m = min(m, mask[ny * W + nx])
            out[y * W + x] = m
    return out


def outline_mask(mask: list[float]) -> list[float]:
    # Stroke width of the hollow (stopped) glyph, in px. The glyph now fills the
    # canvas, so a thin erode looked spindly in the menu bar — keep it ~2.6px so
    # the outline reads at a glance.
    eroded = erode_mask(mask, 3.4)
    return [clamp(mask[i] - eroded[i], 0.0, 1.0) for i in range(W * H)]


def disc(px: float, py: float, cx: float, cy: float, rr: float) -> float:
    return clamp(rr + 0.5 - math.hypot(px - cx, py - cy), 0.0, 1.0)


def rounded_rect(
    px: float,
    py: float,
    cx: float,
    cy: float,
    hw: float,
    hh: float,
    radius: float,
) -> float:
    qx = abs(px - cx) - (hw - radius)
    qy = abs(py - cy) - (hh - radius)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return clamp(0.5 - (outside + inside - radius), 0.0, 1.0)


def exclamation(px: float, py: float, padded: bool = False) -> float:
    pad = 1.9 if padded else 0.0
    # Centered horizontally; sized off the height so it stays proportionate
    # regardless of the (aspect-driven) canvas width.
    bar = rounded_rect(
        px,
        py,
        cx=W * 0.5,
        cy=H * 0.54,
        hw=H * 0.035 + pad,
        hh=H * 0.16 + pad,
        radius=H * 0.025 + pad,
    )
    dot = disc(px, py, W * 0.5, H * 0.75, H * 0.045 + pad)
    return max(bar, dot)


def gen(logo_mask: list[float], with_error: bool = False) -> str:
    buf = bytearray(W * H * 4)

    for y in range(H):
        for x in range(W):
            px, py = float(x), float(y)
            a = logo_mask[y * W + x]
            if with_error:
                a *= 1.0 - exclamation(px, py, padded=True)
                a = max(a, exclamation(px, py))

            i = (y * W + x) * 4
            r, g, b = INK
            buf[i] = r
            buf[i + 1] = g
            buf[i + 2] = b
            buf[i + 3] = int(round(clamp(a, 0.0, 1.0) * 255))
    return base64.b64encode(png(buf, W, H)).decode()


def dart(constants: dict[str, str]) -> str:
    return f'''/// Base64-encoded tray status icons (36px-tall RGBA PNGs; width follows the
/// mark's aspect), generated by `tool/gen_tray_icons.py` from the macOS AppIcon
/// foreground mark.
///
/// The glyph is monochrome so it remains legible in the menu bar: stopped uses
/// an outlined mountain mark, active states use a filled mark, and error states
/// add an exclamation mark. Embedded as base64 so no asset wiring is needed;
/// loaded via `Image.fromBase64`.
library;

class TrayIcons {{
  TrayIcons._();

  static const String stopped =
      '{constants["stopped"]}';

  static const String starting =
      '{constants["starting"]}';

  static const String running =
      '{constants["running"]}';

  static const String error =
      '{constants["error"]}';

  static const String needsLogin =
      '{constants["needsLogin"]}';
}}
'''


def main() -> None:
    filled = app_icon_mask(APP_ICON)
    outlined = outline_mask(filled)
    error = gen(filled, with_error=True)
    constants = {
        "stopped": gen(outlined),
        "starting": gen(filled),
        "running": gen(filled),
        "error": error,
        "needsLogin": error,
    }
    OUT.write_text(dart(constants), encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
