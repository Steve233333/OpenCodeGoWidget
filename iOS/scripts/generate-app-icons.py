#!/usr/bin/env python3
"""Create full-bleed iOS app icons from the existing mac-style source artwork.

The original PNG has a rounded dark tile sitting on a white square. iOS applies
its own icon mask, so the white corners leaked through as a pale, jagged halo.
This script reconstructs the outer gradient, removes the pre-rounded edge, and
exports the exact legacy icon sizes bundled by Info.plist.
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
OUTPUT = ROOT / "Resources/AppIcons"

ICONS = {
    "AppIcon60x60@2x.png": 120,
    "AppIcon60x60@3x.png": 180,
    "AppIcon76x76@2x.png": 152,
    "AppIcon83.5x83.5@2x.png": 167,
}


def bilinear_background(size: int) -> Image.Image:
    source = np.asarray(Image.open(SOURCE).convert("RGB"), dtype=np.float32)
    anchors = np.array(
        [
            source[100, 100],
            source[100, 924],
            source[924, 100],
            source[924, 924],
        ],
        dtype=np.float32,
    )
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    x /= size - 1
    y /= size - 1
    top = anchors[0][None, :] * (1 - x[..., None]) + anchors[1][None, :] * x[..., None]
    bottom = anchors[2][None, :] * (1 - x[..., None]) + anchors[3][None, :] * x[..., None]
    pixels = top * (1 - y[..., None]) + bottom * y[..., None]
    return Image.fromarray(np.clip(pixels, 0, 255).astype(np.uint8), "RGB")


def full_bleed_icon() -> Image.Image:
    source = Image.open(SOURCE).convert("RGB")
    size = source.width
    background = bilinear_background(size)

    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=280, fill=255)
    # Drop the original anti-aliased rim so no white fringe survives the mask.
    mask = mask.filter(ImageFilter.MinFilter(5))
    mask = mask.filter(ImageFilter.GaussianBlur(2))

    result = background.copy()
    result.paste(source, (0, 0), mask)
    return result


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    master = full_bleed_icon()
    for filename, pixels in ICONS.items():
        icon = master.resize((pixels, pixels), Image.Resampling.LANCZOS)
        icon.convert("RGB").save(OUTPUT / filename, format="PNG", optimize=True)
        print(f"{OUTPUT / filename}  {pixels}x{pixels}")


if __name__ == "__main__":
    main()
