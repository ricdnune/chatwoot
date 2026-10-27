#!/usr/bin/env python3
"""Builds the Terranet brand assets from the ORIGINAL raster logo (Pillow only, deterministic).

Nothing is vectorised, recoloured or distorted: the only operations are (1) turning the opaque white background into
transparency (per-pixel alpha derived from the flat fill colour of each glyph, so every colour is exactly the original),
(2) cropping, (3) placing the untouched pixels on a white badge/square where a light backing is required and
(4) resampling (Lanczos). The winged "T" is isolated as its own connected components of the original bitmap
(no pixel of the letter "e" is used). All outputs are PROVISIONAL until Terranet supplies the official vector logo.

Usage: python3 terranet/branding/build_assets.py            # writes public/brand-assets/terranet/ and the public/ icon set
       python3 terranet/branding/build_assets.py --check    # verifies source hash, writes nothing
"""
import hashlib, json, sys
from collections import Counter, deque
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "terranet/branding/source/terranet-logo-original.png"
SOURCE_SHA256 = (Path(__file__).parent / "source" / "SHA256").read_text().split()[0]
OUT = ROOT / "public/brand-assets/terranet"
PUBLIC = ROOT / "public"
BADGE_RED = (255, 56, 45)  # same red as upstream's favicon-badge-*.png


def load():
    digest = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    if digest != SOURCE_SHA256:
        sys.exit(f"source logo hash mismatch: {digest} != {SOURCE_SHA256}")
    return Image.open(SOURCE).convert("RGBA")


def components(img):
    """8-connected components of non-white pixels -> {id: (bbox, pixel list)}."""
    w, h = img.size
    px = img.load()
    seen = [[0] * w for _ in range(h)]
    comps, n = {}, 0
    for y in range(h):
        for x in range(w):
            if sum(px[x, y][:3]) < 720 and not seen[y][x]:
                n += 1
                q, pts = deque([(x, y)]), []
                seen[y][x] = n
                while q:
                    cx, cy = q.popleft()
                    pts.append((cx, cy))
                    for dy in (-1, 0, 1):
                        for dx in (-1, 0, 1):
                            nx, ny = cx + dx, cy + dy
                            if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and sum(px[nx, ny][:3]) < 720:
                                seen[ny][nx] = n
                                q.append((nx, ny))
                if len(pts) > 150:
                    comps[n] = pts
    return comps


def extract(img, comps, ids):
    """Transparent RGBA made of the given components; colour = the component's flat fill, alpha from distance to white."""
    px = img.load()
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    op = out.load()
    for i in ids:
        pts = comps[i]
        fill = Counter(px[x, y][:3] for x, y in pts).most_common(1)[0][0]
        ch = max(range(3), key=lambda c: 255 - fill[c])  # channel with the most contrast against white
        for x, y in pts:
            a = (255 - px[x, y][ch]) / (255 - fill[ch])
            op[x, y] = (*fill, max(0, min(255, round(a * 255))))
    return out


def trim(img, pad=0):
    l, t, r, b = img.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    return img.crop((l - pad, t - pad, r + pad, b + pad))


def on_white(img, size, glyph_ratio, rounded=True):
    """Square canvas, white (rounded) background, glyph centred and scaled to glyph_ratio of the side."""
    scale = 4  # supersample the rounded mask for clean edges
    big = size * scale
    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(canvas).rounded_rectangle((0, 0, big - 1, big - 1), radius=int(big * 0.22) if rounded else 0, fill=(255, 255, 255, 255))
    g = img.copy()
    k = glyph_ratio * big / max(g.size)
    g = g.resize((max(1, round(g.width * k)), max(1, round(g.height * k))), Image.LANCZOS)
    canvas.alpha_composite(g, ((big - g.width) // 2, (big - g.height) // 2))
    return canvas.resize((size, size), Image.LANCZOS)


def badge(icon):
    n = icon.width
    big = icon.resize((n * 4, n * 4), Image.LANCZOS)
    d = ImageDraw.Draw(big)
    r, cx, cy = int(n * 4 * 0.2), int(n * 4 * 0.78), int(n * 4 * 0.22)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(*BADGE_RED, 255))
    return big.resize((n, n), Image.LANCZOS)


def main(check_only):
    img = load()
    comps = components(img)
    boxes = {i: (min(x for x, _ in p), min(y for _, y in p), max(x for x, _ in p), max(y for _, y in p)) for i, p in comps.items()}
    ordered = sorted(boxes, key=lambda i: boxes[i][0])
    # winged T = the component starting at the far left plus the crossbar flap that sits above the "e" (bbox top < 100)
    t_ids = [i for i in ordered if boxes[i][0] < 150 and (boxes[i][1] < 100 or boxes[i][0] < 30)]
    assert len(t_ids) == 2, f"expected 2 components for the winged T, got {t_ids}: {boxes}"
    if check_only:
        print("source hash OK; components:", len(comps), "winged-T ids:", t_ids)
        return
    full = trim(extract(img, comps, list(comps)), pad=2)
    mark = trim(extract(img, comps, t_ids), pad=2)
    OUT.mkdir(parents=True, exist_ok=True)

    full.save(OUT / "logo.png", optimize=True)                                   # light theme: transparent
    # dark theme: untouched logo on a white rounded badge (the indigo is not legible on a dark surface)
    pad = round(full.height * 0.2)
    badge_img = Image.new("RGBA", (full.width + 2 * pad, full.height + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(badge_img).rounded_rectangle((0, 0, badge_img.width - 1, badge_img.height - 1), radius=round(full.height * 0.26), fill=(255, 255, 255, 255))
    badge_img.alpha_composite(full, (pad, pad))
    badge_img.save(OUT / "logo_dark.png", optimize=True)
    mark.save(OUT / "isotype.png", optimize=True)
    master = on_white(mark, 512, 0.62)
    master.save(OUT / "logo_thumbnail.png", optimize=True)                      # sidebar/account switcher + 512 icon

    for n in (16, 32, 96, 512):
        # small favicons need a bigger glyph to stay legible in a browser tab
        icon = on_white(mark, n, 0.8) if n < 512 else master
        icon.save(PUBLIC / f"favicon-{n}x{n}.png", optimize=True)
        if n != 512:
            badge(icon).save(PUBLIC / f"favicon-badge-{n}x{n}.png", optimize=True)
    flat = lambda n: on_white(mark, n, 0.62, rounded=False)                      # OS launchers round/crop themselves
    for n in (36, 48, 72, 96, 144, 192):
        flat(n).save(PUBLIC / f"android-icon-{n}x{n}.png", optimize=True)
    for n in (57, 60, 72, 76, 114, 120, 144, 152, 180):
        flat(n).save(PUBLIC / f"apple-icon-{n}x{n}.png", optimize=True)
    flat(180).save(PUBLIC / "apple-icon.png", optimize=True)
    flat(180).save(PUBLIC / "apple-icon-precomposed.png", optimize=True)
    flat(180).save(PUBLIC / "apple-touch-icon.png", optimize=True)               # upstream ships this one empty (0 bytes)
    flat(180).save(PUBLIC / "apple-touch-icon-precomposed.png", optimize=True)
    for n in (70, 144, 150, 310):
        flat(n).save(PUBLIC / f"ms-icon-{n}x{n}.png", optimize=True)
    print("assets written:", sorted(p.name for p in OUT.iterdir()))


if __name__ == "__main__":
    main("--check" in sys.argv)
