"""Generate OpenLark.icns: black gradient rounded square with white waveform."""
from __future__ import annotations

import math
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "build"
ICONSET_DIR = OUT_DIR / "Icon.iconset"
ICNS_PATH = OUT_DIR / "OpenLark.icns"

# macOS app icon set, each size in points, both @1x and @2x.
SIZES = [16, 32, 128, 256, 512]


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return (
        int(a[0] + (b[0] - a[0]) * t),
        int(a[1] + (b[1] - a[1]) * t),
        int(a[2] + (b[2] - a[2]) * t),
    )


def make_icon(size: int) -> Image.Image:
    """Render a single icon at the given pixel size."""
    # supersample for crisp edges, then downscale
    scale = 2 if size <= 64 else 1
    s = size * scale

    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # macOS Big Sur icon mask: ~22.5% corner radius based on bounding rect
    corner_radius = int(s * 0.225)
    inset = int(s * 0.07)  # leave breathing room for the icon
    box = (inset, inset, s - inset, s - inset)

    # ---- background: diagonal gradient from dark-graphite to near-black ----
    bg = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    bg_draw = ImageDraw.Draw(bg)

    top_color = (130, 132, 140)     # bright graphite highlight (top-left)
    mid_color = (38, 38, 42)        # mid graphite
    bottom_color = (4, 4, 6)        # near-black (bottom-right)

    grad = Image.new("RGB", (s, s), bottom_color)
    grad_pixels = grad.load()
    for y in range(s):
        for x in range(s):
            # Account for inset so the highlight peaks INSIDE the visible square,
            # not behind the rounded corner clip.
            nx = (x - inset) / max(1, s - 2 * inset)
            ny = (y - inset) / max(1, s - 2 * inset)
            t = max(0.0, min(1.0, (nx + ny) / 2))
            # Three-stop ease: bright → mid → black
            if t < 0.45:
                k = t / 0.45
                grad_pixels[x, y] = lerp(top_color, mid_color, k)
            else:
                k = (t - 0.45) / 0.55
                grad_pixels[x, y] = lerp(mid_color, bottom_color, k)

    # rounded mask
    mask = Image.new("L", (s, s), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(box, radius=corner_radius, fill=255)
    rounded = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    rounded.paste(grad, (0, 0), mask)

    # ---- inner glow / specular highlight on top edge ----
    highlight = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    h_draw = ImageDraw.Draw(highlight)
    h_inset = inset + int(s * 0.01)
    h_box = (h_inset, h_inset, s - h_inset, h_inset + int(s * 0.22))
    h_draw.rounded_rectangle(h_box, radius=corner_radius, fill=(255, 255, 255, 50))
    highlight = highlight.filter(ImageFilter.GaussianBlur(radius=s * 0.022))
    rounded = Image.alpha_composite(rounded, highlight)

    # ---- subtle bottom darken for depth ----
    shade = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sh_draw = ImageDraw.Draw(shade)
    sh_box = (inset, s - inset - int(s * 0.20), s - inset, s - inset)
    sh_draw.rounded_rectangle(sh_box, radius=corner_radius, fill=(0, 0, 0, 50))
    shade = shade.filter(ImageFilter.GaussianBlur(radius=s * 0.025))
    rounded = Image.alpha_composite(rounded, shade)

    # ---- waveform bars (white) ----
    wave = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    w_draw = ImageDraw.Draw(wave)

    cx, cy = s / 2, s / 2
    bar_count = 9
    bar_width = max(1, int(s * 0.045))
    bar_gap = max(1, int(s * 0.038))
    total_width = bar_count * bar_width + (bar_count - 1) * bar_gap
    start_x = cx - total_width / 2

    # heights: symmetric, taller in middle (typical waveform shape)
    height_factors = [0.20, 0.38, 0.55, 0.82, 1.0, 0.82, 0.55, 0.38, 0.20]
    max_height = s * 0.42

    for i in range(bar_count):
        h = max_height * height_factors[i]
        x0 = start_x + i * (bar_width + bar_gap)
        y0 = cy - h / 2
        x1 = x0 + bar_width
        y1 = cy + h / 2
        w_draw.rounded_rectangle((x0, y0, x1, y1), radius=bar_width / 2, fill=(255, 255, 255, 240))

    # gentle white glow behind the bars
    glow = wave.filter(ImageFilter.GaussianBlur(radius=s * 0.025))
    glow_dim = Image.eval(glow.split()[3], lambda a: int(a * 0.35))
    glow.putalpha(glow_dim)
    rounded = Image.alpha_composite(rounded, glow)
    rounded = Image.alpha_composite(rounded, wave)

    if scale > 1:
        rounded = rounded.resize((size, size), Image.LANCZOS)
    return rounded


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    if ICONSET_DIR.exists():
        shutil.rmtree(ICONSET_DIR)
    ICONSET_DIR.mkdir()

    # Render a single big master at 1024x1024 then downscale for crispness,
    # or render at each native size. We do per-size for sharper small icons.
    for size in SIZES:
        for scale in (1, 2):
            px = size * scale
            img = make_icon(px)
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            img.save(ICONSET_DIR / name, "PNG")
            print(f"› wrote {name} ({px}px)")

    # Compile .icns
    subprocess.run(
        ["iconutil", "--convert", "icns", str(ICONSET_DIR), "--output", str(ICNS_PATH)],
        check=True,
    )
    print(f"✓ {ICNS_PATH}")

    # Keep a 1024 preview for sanity
    preview = ICONSET_DIR / "icon_512x512@2x.png"
    if preview.exists():
        shutil.copy(preview, OUT_DIR / "OpenLark-icon-preview.png")
        print(f"✓ preview: {OUT_DIR / 'OpenLark-icon-preview.png'}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
