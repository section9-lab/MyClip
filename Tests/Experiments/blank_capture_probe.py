#!/usr/bin/env python3
"""Offline blank-image experiment; never imported by MyClip or writes to its library.

Requires Pillow. Run without arguments for synthetic counterexamples, or pass local
screenshots with --blank / --content. --body-top is a MANUAL geometry assumption,
not an implementation of browser content-area detection. Results go to stdout.
"""
import argparse
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageStat


def background_ratio(image):
    background = tuple(ImageStat.Stat(image).median)
    channels = ImageChops.difference(image, Image.new("RGB", image.size, background)).split()
    difference = ImageChops.lighter(ImageChops.lighter(channels[0], channels[1]), channels[2])
    return sum(difference.histogram()[:7]) / (image.width * image.height)


def analyze(name, image, body_box, blank):
    image = image.convert("RGB")
    body = image.crop(body_box)
    width, height = image.size
    center = image.crop((int(width * .05), int(height * .16), int(width * .95), int(height * .95)))
    center_ratio = background_ratio(center)
    body_ratio = background_ratio(body)
    # Conservative baseline: any unexplained pixel variation vetoes blankness.
    # Even this result relies on the caller having supplied the correct body box.
    uniform = all(low == high for low, high in body.getextrema())
    return {
        "sample": name, "expected_blank": blank,
        "center_background_ratio": round(center_ratio, 6),
        "body_background_ratio": round(body_ratio, 6),
        "center_ratio_would_skip": center_ratio >= .99,
        "body_ratio_would_skip": body_ratio >= .99,
        "pixel_veto_would_skip": uniform,
    }


def synthetic_samples():
    width, height, top = 1280, 900, 80
    body_box = (0, top, width, height)

    def page(color=(255, 255, 255)):
        image = Image.new("RGB", (width, height), color)
        draw = ImageDraw.Draw(image)
        draw.rectangle((0, 0, width, top - 1), fill=(235, 235, 235))
        draw.text((40, 25), "Browser toolbar / Address / Tabs", fill=(20, 20, 20))
        return image, draw

    for name, color in [("white", (255, 255, 255)), ("near_white", (250, 250, 250)),
                        ("gray", (228, 229, 231)), ("dark", (24, 24, 24))]:
        image, _ = page(color)
        yield name, image, body_box, True

    for name, position, color, text in [
        ("one_line", (100, 300), (20, 20, 20), "A short but important note"),
        ("one_number", (100, 300), (20, 20, 20), "7"),
        ("top_text", (30, top + 5), (20, 20, 20), "Only content at the top"),
        ("bottom_text", (20, height - 20), (20, 20, 20), "Only content in the corner"),
        ("low_contrast_text", (100, 300), (250, 250, 250), "Low contrast content"),
    ]:
        image, draw = page()
        draw.text(position, text, fill=color)
        yield name, image, body_box, False

    image, draw = page()
    draw.line((200, 300, 500, 300), fill=(100, 100, 100), width=1)
    yield "thin_line", image, body_box, False

    image, draw = page()
    draw.line((100, 500, 400, 500, 400, 200), fill=(60, 60, 60), width=1)
    draw.line((100, 470, 200, 400, 300, 420, 380, 230), fill=(30, 100, 220), width=2)
    yield "chart_without_text", image, body_box, False

    image, draw = page()
    for y in range(200, 300):
        for x in range(200, 300):
            draw.point((x, y), fill=((x * 13) % 256, (y * 17) % 256, (x * y) % 256))
    yield "image_without_text", image, body_box, False

    image, draw = page((228, 229, 231))
    draw.rounded_rectangle((width - 70, height - 30, width - 10, height - 6), radius=10, fill=(145, 145, 145))
    draw.text((width - 58, height - 24), "Edit", fill=(255, 255, 255))
    yield "blank_with_browser_control", image, body_box, True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--blank", action="append", type=Path, default=[])
    parser.add_argument("--content", action="append", type=Path, default=[])
    parser.add_argument("--body-top", type=float, default=.085,
                        help="Manually assumed top edge of body, as a fraction of image height")
    args = parser.parse_args()
    if not 0 <= args.body_top < 1:
        parser.error("--body-top must be in [0, 1)")
    samples = list(synthetic_samples())
    for blank, paths in [(True, args.blank), (False, args.content)]:
        for path in paths:
            with Image.open(path) as source:
                image = source.convert("RGB")
            box = (0, int(image.height * args.body_top), image.width, image.height)
            samples.append((path.name, image, box, blank))
    rows = [analyze(*sample) for sample in samples]
    summary = {}
    for rule in ["center_ratio_would_skip", "body_ratio_would_skip", "pixel_veto_would_skip"]:
        summary[rule] = {
            "blank_detected": sum(row[rule] and row["expected_blank"] for row in rows),
            "blank_missed": sum(not row[rule] and row["expected_blank"] for row in rows),
            "content_incorrectly_skipped": sum(row[rule] and not row["expected_blank"] for row in rows),
        }
    print(json.dumps({"geometry": "manual assumption; AX geometry and OCR not validated",
                      "sample_count": len(rows), "summary": summary, "samples": rows}, indent=2))


if __name__ == "__main__":
    main()
