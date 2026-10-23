#!/usr/bin/env python3
"""Draws LotsOfMedia's app icons: every style in green (Forest colors), each with light,
dark and tinted variants, plus small light and dark previews for the in-app picker.

Run from the repo root:  python3 scripts/make-icons.py
Rendering uses macOS Quick Look (qlmanage); PIL makes the final opaque PNGs.
LoM (Lettermark) is the primary icon (AppIcon). The Retro TV style is the original
artwork and isn't redrawn here.
"""
import json
import os
import subprocess
import sys
import tempfile

from PIL import Image

ASSETS = "LotsOfMedia/Resources/Assets.xcassets"
SIZE = 1024
PREVIEW = 180

# Per theme: accent, bright background, deep background, ink (on accent), paper.
THEMES = {
    "Forest":   dict(A="#5CD98C", B="#1F9D55", D="#07130C", K="#04120A", P="#F2F7F0"),
}

STYLES = ["TVNote", "PlayNote", "Stacked", "Speaker", "Cassette", "VHS", "Vinyl", "Lettermark", "Glow"]


def art(style, c, dark):
    """SVG body in a 150-unit square. `dark` draws the iOS dark-mode variant."""
    A, B, D, K, P = c["A"], c["B"], c["D"], c["K"], c["P"]
    bg = "#000000" if dark else None
    if style == "TVNote":
        body = "#2B313B" if dark else "#FFFFFF"
        return f'''<rect width="150" height="150" fill="{bg or B}"/>
<line x1="62" y1="44" x2="50" y2="26" stroke="{body}" stroke-width="6" stroke-linecap="round"/>
<line x1="88" y1="44" x2="100" y2="26" stroke="{body}" stroke-width="6" stroke-linecap="round"/>
<rect x="26" y="44" width="98" height="74" rx="16" fill="{body}"/>
<rect x="36" y="53" width="78" height="56" rx="9" fill="{'#000000' if dark else D}"/>
<rect x="40" y="118" width="14" height="8" rx="3" fill="{body}"/><rect x="96" y="118" width="14" height="8" rx="3" fill="{body}"/>
<ellipse cx="68" cy="95" rx="9" ry="7" fill="{A}"/><rect x="74" y="64" width="5" height="32" fill="{A}"/>
<path d="M79 64 Q95 70 90 84 Q88 74 79 72 Z" fill="{A}"/>'''
    if style == "PlayNote":
        return f'''<rect width="150" height="150" fill="{bg or D}"/>
<path d="M46 40 L46 112 L104 76 Z" fill="{A}" stroke="{A}" stroke-width="8" stroke-linejoin="round"/>
<rect x="100" y="30" width="8" height="48" rx="3" fill="{A}"/>
<path d="M108 30 Q128 38 122 58 Q118 46 108 44 Z" fill="{A}"/>'''
    if style == "Stacked":
        return f'''<rect width="150" height="150" fill="{bg or D}"/>
<g transform="rotate(-14 75 80)"><rect x="38" y="40" width="74" height="74" rx="10" fill="#F2A33A"/><circle cx="75" cy="77" r="22" fill="#7A4A10"/><circle cx="75" cy="77" r="6" fill="#F2A33A"/></g>
<g transform="rotate(10 75 80)"><rect x="38" y="40" width="74" height="74" rx="10" fill="#8B5CF6"/>
<rect x="44" y="46" width="8" height="8" rx="2" fill="#2E1A66"/><rect x="44" y="62" width="8" height="8" rx="2" fill="#2E1A66"/><rect x="44" y="78" width="8" height="8" rx="2" fill="#2E1A66"/><rect x="44" y="94" width="8" height="8" rx="2" fill="#2E1A66"/></g>
<rect x="44" y="50" width="70" height="70" rx="10" fill="{A}"/><path d="M70 70 L70 100 L94 85 Z" fill="{K}"/>'''
    if style == "Speaker":
        dots = "".join(f'<circle cx="{x}" cy="{y}" r="3"/>' for y in (46, 59, 72, 85, 98) for x in (34, 47, 60))
        return f'''<rect width="150" height="150" fill="{bg or D}"/>
<rect x="22" y="34" width="50" height="82" rx="10" fill="#1A2533"/><g fill="#3E5068">{dots}</g>
<rect x="78" y="34" width="50" height="82" rx="10" fill="{A}"/><path d="M96 62 L96 88 L116 75 Z" fill="{K}"/>'''
    if style == "Cassette":
        label = "#3A414D" if dark else P
        shell = "#2B313B" if dark else "#1D2430"
        return f'''<rect width="150" height="150" fill="{bg or B}"/>
<rect x="20" y="38" width="110" height="76" rx="10" fill="{shell}"/>
<rect x="30" y="46" width="90" height="30" rx="5" fill="{label}"/>
<rect x="60" y="50" width="30" height="22" rx="4" fill="{A}"/><path d="M71 55 L71 67 L80 61 Z" fill="{K}"/>
<circle cx="52" cy="92" r="10" fill="{label}"/><circle cx="98" cy="92" r="10" fill="{label}"/>
<circle cx="52" cy="92" r="4" fill="{shell}"/><circle cx="98" cy="92" r="4" fill="{shell}"/>
<path d="M44 114 L50 104 L100 104 L106 114 Z" fill="#2E3644"/>'''
    if style == "VHS":
        return f'''<rect width="150" height="150" fill="{bg or B}"/>
<rect x="22" y="40" width="106" height="72" rx="7" fill="{'#2B313B' if dark else '#121418'}"/>
<rect x="32" y="48" width="86" height="26" rx="4" fill="{A}"/><path d="M68 53 L68 69 L80 61 Z" fill="{K}"/>
<rect x="44" y="84" width="62" height="18" rx="4" fill="#2A2E36"/>
<circle cx="58" cy="93" r="5" fill="#121418"/><circle cx="92" cy="93" r="5" fill="#121418"/>'''
    if style == "Vinyl":
        rings = "".join(f'<circle cx="75" cy="75" r="{r}"/>' for r in (47, 41, 35, 29))
        return f'''<rect width="150" height="150" fill="{bg or D}"/>
<circle cx="75" cy="75" r="54" fill="#0B0C10" stroke="{'#1E2229' if dark else 'none'}" stroke-width="1"/>
<g fill="none" stroke="#262B33" stroke-width="1.5">{rings}</g>
<circle cx="75" cy="75" r="21" fill="{A}"/><path d="M69 64 L69 86 L87 75 Z" fill="{K}"/>'''
    if style == "Lettermark":
        return f'''<rect width="150" height="150" fill="{bg or A}"/>
<text x="75" y="94" text-anchor="middle" style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:54px;font-weight:900;letter-spacing:-2px" fill="{A if dark else K}">LoM</text>'''
    if style == "Glow":
        return f'''<rect width="150" height="150" fill="{bg or '#05070B'}"/>
<circle cx="75" cy="75" r="50" fill="{A}" opacity="0.10"/><circle cx="75" cy="75" r="40" fill="{A}" opacity="0.18"/>
<circle cx="75" cy="75" r="30" fill="{A}"/><path d="M67 61 L67 89 L91 75 Z" fill="{bg or '#05070B'}"/>'''
    raise ValueError(style)


def render(jobs):
    """jobs: [(svg_text, out_png)] -> opaque RGB PNGs at SIZE."""
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for i, (svg, _) in enumerate(jobs):
            p = os.path.join(tmp, f"{i}.svg")
            with open(p, "w") as f:
                f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 150 150">{svg}</svg>')
            paths.append(p)
        for start in range(0, len(paths), 40):
            subprocess.run(["qlmanage", "-t", "-s", str(SIZE), "-o", tmp] + paths[start:start + 40],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for i, (_, out) in enumerate(jobs):
            img = Image.open(os.path.join(tmp, f"{i}.svg.png")).convert("RGB")
            if img.size != (SIZE, SIZE):
                img = img.resize((SIZE, SIZE), Image.LANCZOS)
            img.save(out, optimize=True)


ICONSET_JSON = {
    "images": [
        {"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}],
         "filename": "icon-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}],
         "filename": "icon-tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        # CarPlay doesn't make its own from the 1024 image.
        {"filename": "carplay-120.png", "idiom": "car", "scale": "2x", "size": "60x60"},
        {"filename": "carplay-180.png", "idiom": "car", "scale": "3x", "size": "60x60"},
    ],
    "info": {"author": "xcode", "version": 1},
}


def tinted(src, out):
    """iOS tinted icons are grayscale; the system adds the tint."""
    img = Image.open(src).convert("L")
    # Lift mid-tones so the glyph stays bright once tinted.
    img = img.point(lambda v: min(255, int(v * 1.35)))
    img.convert("RGB").save(out, optimize=True)


def carplay(d):
    img = Image.open(os.path.join(d, "icon.png")).convert("RGB")
    for px in (120, 180):
        img.resize((px, px), Image.LANCZOS).save(os.path.join(d, f"carplay-{px}.png"), optimize=True)


def preview(src, name):
    d = os.path.join(ASSETS, "IconPreviews", f"{name}.imageset")
    os.makedirs(d, exist_ok=True)
    Image.open(src).resize((PREVIEW, PREVIEW), Image.LANCZOS).save(os.path.join(d, "preview.png"), optimize=True)
    with open(os.path.join(d, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "preview.png", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, f, indent=2)


def iconset(style, theme):
    """LoM is the primary icon; everything else is an alternate."""
    name = "AppIcon" if style == "Lettermark" else f"Icon-{style}-{theme}"
    return os.path.join(ASSETS, f"{name}.appiconset")


def main():
    os.makedirs(os.path.join(ASSETS, "IconPreviews"), exist_ok=True)
    with open(os.path.join(ASSETS, "IconPreviews", "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": True}}, f, indent=2)

    jobs = []
    for style in STYLES:
        for theme, colors in THEMES.items():
            d = iconset(style, theme)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "Contents.json"), "w") as f:
                json.dump(ICONSET_JSON, f, indent=2)
            jobs.append((art(style, colors, dark=False), os.path.join(d, "icon.png")))
            jobs.append((art(style, colors, dark=True), os.path.join(d, "icon-dark.png")))
    render(jobs)

    for style in STYLES:
        for theme in THEMES:
            d = iconset(style, theme)
            tinted(os.path.join(d, "icon-dark.png"), os.path.join(d, "icon-tinted.png"))
            carplay(d)
            preview(os.path.join(d, "icon.png"), f"{style}-{theme}")
            preview(os.path.join(d, "icon-dark.png"), f"{style}-{theme}-Dark")

    # The original Retro TV artwork: previews from its existing icon sets.
    carplay(os.path.join(ASSETS, "Icon-RetroTV-Forest.appiconset"))
    preview(os.path.join(ASSETS, "Icon-RetroTV-Forest.appiconset", "icon.png"), "RetroTV-Forest")
    preview(os.path.join(ASSETS, "Icon-RetroTV-Forest.appiconset", "icon-dark.png"), "RetroTV-Forest-Dark")
    print(f"{len(STYLES) * len(THEMES)} icon sets written", file=sys.stderr)


if __name__ == "__main__":
    main()
