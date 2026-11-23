#!/usr/bin/env python3
"""Render the Workers site's navy/lavender glass palette at 1x and 2x."""
from pathlib import Path
import json
import math
import subprocess
import sys
import tempfile
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
LAYOUT = json.loads((ROOT / 'scripts/dmg-layout.json').read_text())
SIZE = tuple(LAYOUT['canvas'])


def font(size, bold=False):
    for path in ['/System/Library/Fonts/SFNS.ttf', '/System/Library/Fonts/Helvetica.ttc']:
        try:
            result = ImageFont.truetype(path, size=size, index=1 if bold and path.endswith('.ttc') else 0)
            return result
        except OSError:
            pass
    return ImageFont.load_default()


def render(scale=1):
    width, height = SIZE
    # Large, soft color fields echo the website without the old decorative leaves.
    small = Image.new('RGB', (225, 140))
    pixels = small.load()
    fields = [(0.13, 0.14, 0.29, (82, 94, 157)), (0.8, 0.16, 0.33, (93, 73, 125)),
              (0.28, 0.79, 0.29, (136, 108, 126)), (0.9, 0.83, 0.31, (41, 66, 104))]
    for y in range(small.height):
        for x in range(small.width):
            color = [17.0, 25.0, 46.0]
            for cx, cy, radius, rgb in fields:
                alpha = math.exp(-((x / small.width - cx)**2 + (y / small.height - cy)**2) / (2 * radius**2)) * 0.68
                color = [a * (1 - alpha) + b * alpha for a, b in zip(color, rgb)]
            pixels[x, y] = tuple(round(v) for v in color)
    canvas = small.resize((width * scale, height * scale), Image.Resampling.LANCZOS).convert('RGBA')
    def box(bounds): return tuple(round(v * scale) for v in bounds)
    def panel(bounds, radius, fill):
        shadow = Image.new('RGBA', canvas.size)
        d = ImageDraw.Draw(shadow)
        d.rounded_rectangle(box((bounds[0], bounds[1] + 7, bounds[2], bounds[3] + 7)), radius=radius * scale, fill=(0, 0, 0, 35))
        canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(12 * scale)))
        surface = Image.new('RGBA', canvas.size)
        d = ImageDraw.Draw(surface)
        d.rounded_rectangle(box(bounds), radius=radius * scale, fill=fill, outline=(255, 255, 255, 38), width=scale)
        canvas.alpha_composite(surface)
    panel((32, 24, 868, 146), 28, (14, 23, 42, 205))
    panel((32, 164, 868, 494), 28, (14, 23, 42, 170))
    logo = Image.open(ROOT / 'MacApp/BrandLogo.png').convert('RGBA')
    logo.thumbnail((76 * scale, 76 * scale), Image.Resampling.LANCZOS)
    canvas.alpha_composite(logo, (58 * scale, 47 * scale))
    d = ImageDraw.Draw(canvas)
    def text(position, value, size, fill, anchor=None, bold=False):
        d.text(tuple(v * scale for v in position), value, font=font(size * scale, bold), fill=fill, anchor=anchor)
    text((155, 46), 'SIM HUB  /  CELLULAR GATEWAY', 10, (239, 178, 154, 255))
    text((153, 67), 'Yume SIMBridge', 29, (244, 246, 251, 255), bold=True)
    text((155, 110), 'macOS 26+   ·   Apple Silicon', 13, (199, 204, 221, 255))
    # Label wells follow the homepage's translucent navy cards. Finder places
    # a two-line application name and a one-line folder name at different baselines.
    for number, x, center_y in [('01', 225, 393), ('02', 675, 393)]:
        bounds = (x - 118, center_y - 26, x + 118, center_y + 26)
        panel(bounds, 16, (140, 157, 193, 120))
        # A translucent vertical highlight gives the small wells the same
        # layered glass material as the homepage cards while preserving the
        # contrast of Finder's system-drawn black labels on picture backgrounds.
        mask = Image.new('L', canvas.size)
        ImageDraw.Draw(mask).rounded_rectangle(box(bounds), radius=16 * scale, fill=255)
        glow = Image.new('RGBA', canvas.size)
        gd = ImageDraw.Draw(glow)
        for row in range(52 * scale):
            alpha = round(115 - row / (52 * scale) * 90)
            gd.line((round(bounds[0] * scale), round(bounds[1] * scale) + row, round(bounds[2] * scale), round(bounds[1] * scale) + row), fill=(190, 204, 232, alpha))
        glow.putalpha(Image.composite(glow.getchannel('A'), Image.new('L',canvas.size), mask))
        canvas.alpha_composite(glow)
        edge = Image.new('RGBA',canvas.size)
        ImageDraw.Draw(edge).rounded_rectangle(box(bounds), radius=16 * scale, outline=(223, 231, 249, 95),width=scale)
        canvas.alpha_composite(edge)
        text((x, 206), number, 11, (196, 201, 220, 255), anchor='mm')
    d = ImageDraw.Draw(canvas)
    accent = (239, 178, 154, 255)
    d.line(box((405, 310, 495, 310)), fill=accent, width=3 * scale)
    d.line(box((480, 296, 495, 310)), fill=accent, width=3 * scale)
    d.line(box((480, 324, 495, 310)), fill=accent, width=3 * scale)
    text((450, 464), 'Drag the app to Applications', 14, (224, 228, 239, 255), anchor='mm')
    text((450, 530), 'Copyright © 2026 Yume internet LLC.', 11, (192, 197, 216, 255), anchor='mm')
    return canvas.convert('RGB')


def main():
    output = Path(sys.argv[1])
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.suffix.lower() in ('.tif', '.tiff'):
        with tempfile.TemporaryDirectory(prefix='yla-dmg-background-') as folder:
            paths = []
            for scale in [1, 2]:
                path = Path(folder) / f'background-{scale}x.tiff'
                render(scale).save(path, dpi=(72 * scale, 72 * scale))
                paths.append(str(path))
            subprocess.run(['/usr/bin/tiffutil', '-cathidpicheck', *paths, '-out', str(output)], check=True)
    else:
        render().save(output)


if __name__ == '__main__':
    main()
