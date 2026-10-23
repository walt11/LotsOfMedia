#!/usr/bin/env python3
"""Draws the Apple TV app icon (three parallax layers) and Top Shelf images from the
LoM design, black with green letters. Run from the repo root:

    python3 scripts/make-tv-icons.py

Writes LotsOfMediaTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets.
"""
import json
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ASSETS = "LotsOfMediaTV/Assets.xcassets"
BRAND = os.path.join(ASSETS, "App Icon & Top Shelf Image.brandassets")
INFO = {"author": "xcode", "version": 1}

ACCENT = (92, 217, 140)       # the icon's green letters
INK = (4, 18, 10)
DEEP = (7, 19, 12)
BLACK = (6, 8, 7)
TINT = (255, 255, 255)        # the app's accent color (white, like its buttons)
SS = 4  # supersampling for smooth edges


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def lettermark(canvas, cx, cy, height, fill):
    """"LoM" in heavy type (Helvetica Bold, like the iOS icon), tightly spaced, centered."""
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", int(height), index=1)
    gap = -height * 2 / 54          # the iOS icon's letter-spacing (-2 at 54)
    d = ImageDraw.Draw(canvas)
    widths = [d.textlength(ch, font=font) for ch in "LoM"]
    total = sum(widths) + gap * 2
    x = cx - total / 2
    for ch, w in zip("LoM", widths):
        d.text((x, cy), ch, font=font, fill=fill, anchor="ls")
        x += w + gap


def layers(w, h, scale=1.0):
    """Back (black with a faint sheen), middle (the letters' shadow) and front (the letters)
    for a w×h icon, after the iOS LoM icon. `scale` sizes the letters."""
    W, H = w * SS, h * SS
    size = H * 0.42 * scale
    cx, base = W / 2, H / 2 + size * 0.36

    back = Image.new("RGBA", (W, H), BLACK + (255,))
    light = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ld = ImageDraw.Draw(light)
    for i in range(30, 0, -1):
        r = H * 0.8 * i / 30
        ld.ellipse([W / 2 - r * 1.5, H * 0.35 - r, W / 2 + r * 1.5, H * 0.35 + r], fill=(255, 255, 255, int(1 + (30 - i) * 0.18)))
    back = Image.alpha_composite(back, light)

    middle = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    lettermark(middle, cx, base + size * 0.05, size, (0, 0, 0, 170))
    middle = middle.filter(ImageFilter.GaussianBlur(size * 0.04))

    front = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    lettermark(front, cx, base, size, ACCENT + (255,))

    def down(img):
        return img.resize((w, h), Image.LANCZOS)
    return down(back).convert("RGB"), down(middle), down(front)


def imagestack(name, sizes, scale=1.0):
    """sizes: [(scale_label, w, h)]."""
    stack = os.path.join(BRAND, f"{name}.imagestack")
    write_json(os.path.join(stack, "Contents.json"),
               {"info": INFO, "layers": [{"filename": f"{n}.imagestacklayer"} for n in ("Front", "Middle", "Back")]})
    rendered = {label: layers(w, h, scale) for label, w, h in sizes}
    for li, layer in enumerate(("Back", "Middle", "Front")):
        d = os.path.join(stack, f"{layer}.imagestacklayer")
        write_json(os.path.join(d, "Contents.json"), {"info": INFO})
        images = []
        for label, _, _ in sizes:
            fn = f"{layer.lower()}@{label}.png"
            os.makedirs(os.path.join(d, "Content.imageset"), exist_ok=True)
            rendered[label][li].save(os.path.join(d, "Content.imageset", fn), optimize=True)
            images.append({"filename": fn, "idiom": "tv", "scale": label})
        write_json(os.path.join(d, "Content.imageset", "Contents.json"), {"images": images, "info": INFO})


def top_shelf(name, sizes):
    d = os.path.join(BRAND, f"{name}.imageset")
    images = []
    for label, w, h in sizes:
        t = int(h * 0.62)                          # a rounded LoM tile on the left
        back, middle, front = layers(t, t, 0.85)
        art = back.convert("RGBA")
        art.alpha_composite(middle)
        art.alpha_composite(front)
        mask = Image.new("L", (t, t), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, t - 1, t - 1], radius=t // 6, fill=255)
        img = Image.new("RGB", (w, h), DEEP)
        x0, y0 = int(w * 0.08), (h - t) // 2
        img.paste(art, (x0, y0), mask)
        draw = ImageDraw.Draw(img)
        # The black tile would vanish into the dark background without an outline.
        draw.rounded_rectangle([x0, y0, x0 + t - 1, y0 + t - 1], radius=t // 6, outline=ACCENT, width=max(2, t // 90))
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", int(h * 0.16))
            small = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", int(h * 0.06))
        except OSError:
            font = small = ImageFont.load_default()
        x = int(w * 0.08) + t + int(h * 0.12)
        draw.text((x, h * 0.36), "LotsOfMedia", font=font, fill=(255, 255, 255))
        draw.text((x, h * 0.58), "Your Plex movies, shows and music", font=small, fill=(150, 160, 175))
        fn = f"{name.lower().replace(' ', '-')}@{label}.png"
        os.makedirs(d, exist_ok=True)
        img.save(os.path.join(d, fn), optimize=True)
        images.append({"filename": fn, "idiom": "tv", "scale": label})
    write_json(os.path.join(d, "Contents.json"), {"images": images, "info": INFO})


def main():
    write_json(os.path.join(ASSETS, "Contents.json"), {"info": INFO})
    write_json(os.path.join(ASSETS, "AccentColor.colorset", "Contents.json"), {
        "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": f"{TINT[0] / 255:.3f}", "green": f"{TINT[1] / 255:.3f}", "blue": f"{TINT[2] / 255:.3f}", "alpha": "1.000"}}}],
        "info": INFO})
    imagestack("App Icon", [("1x", 400, 240), ("2x", 800, 480)])
    imagestack("App Icon - App Store", [("1x", 1280, 768)])
    top_shelf("Top Shelf Image", [("1x", 1920, 720), ("2x", 3840, 1440)])
    top_shelf("Top Shelf Image Wide", [("1x", 2320, 720), ("2x", 4640, 1440)])
    write_json(os.path.join(BRAND, "Contents.json"), {"assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ], "info": INFO})


if __name__ == "__main__":
    main()
