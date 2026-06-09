#!/usr/bin/env python3
"""Render an alphabet (or arbitrary string) on a black background, one row.

Used by demo_alphabet.sh as the source image for an end-to-end pipeline demo.
"""

import argparse
import sys

from PIL import Image, ImageDraw, ImageFont


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("output", help="output PNG path")
    ap.add_argument("--height", type=int, default=1024, help="image height (px)")
    ap.add_argument("--letter-ratio", type=float, default=0.6,
                    help="letter height as fraction of image height")
    ap.add_argument("--spacing", type=int, default=10, help="px between letters")
    ap.add_argument("--margin", type=int, default=20, help="left/right margin (px)")
    ap.add_argument("--letters", default="ABCDEFGHIJKLMNOPQRSTUVWXYZ",
                    help="characters to render")
    ap.add_argument("--font", default="/System/Library/Fonts/Helvetica.ttc",
                    help="path to TrueType font file")
    args = ap.parse_args()

    letter_target = int(args.height * args.letter_ratio)

    font = ImageFont.truetype(args.font, letter_target)
    bbox_A = font.getbbox("A")
    font_size = int(letter_target * letter_target / (bbox_A[3] - bbox_A[1]))
    font = ImageFont.truetype(args.font, font_size)

    masks = []
    for c in args.letters:
        bbox = font.getbbox(c)
        w = bbox[2] - bbox[0]
        h = bbox[3] - bbox[1]
        canvas = Image.new("L", (w, h), 0)
        ImageDraw.Draw(canvas).text((-bbox[0], -bbox[1]), c, font=font, fill=255)
        masks.append(canvas)

    total_w = sum(m.width for m in masks) + args.spacing * (len(args.letters) - 1) + 2 * args.margin
    img = Image.new("RGB", (total_w, args.height), (0, 0, 0))
    x = args.margin
    y_center = args.height // 2
    for m in masks:
        y = y_center - m.height // 2
        img.paste((255, 255, 255), (x, y, x + m.width, y + m.height), mask=m)
        x += m.width + args.spacing

    img.save(args.output)
    print(f"wrote {args.output} ({total_w}x{args.height}, font size {font_size})")


if __name__ == "__main__":
    main()
