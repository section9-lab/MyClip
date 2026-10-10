"""Offline Safari empty-body hypothesis. Never imported by the application."""
from dataclasses import dataclass
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


@dataclass
class Template:
    image: Image.Image
    body_top: int
    control_bounds: tuple[int, int, int, int]
    corner_size: int
    background: tuple[int, int, int]


def classify(image, analysis, content_bounds, bundle_ids, titles, template):
    def keep(reason):
        return {'decision': 'keep', 'reason': reason}

    if analysis.get('status') == 'unavailable' or analysis.get('regionsTruncated'):
        return keep('incomplete_analysis')
    if analysis.get('status') not in ('candidate_with_regions', 'uniform_candidate'):
        return keep('not_color_candidate')
    if set(bundle_ids) != {'com.apple.Safari'}:
        return keep('unsupported_app')
    if image.info.get('icc_profile'):
        return keep('unsupported_color_profile')
    width, height = image.size
    if (height != template.image.height or width <= 2 * template.corner_size
            or content_bounds != [0, template.body_top, width, height - template.body_top]):
        return keep('unsupported_geometry')
    background = np.array(analysis['backgroundRGB'], dtype=np.int16)
    if not (np.all(background == 255) or np.max(np.abs(background - template.background)) <= 3):
        return keep('unsupported_background')
    # Observed Safari style: an opaque 1-pixel divider at the supplied body boundary.
    # This guards this offline layout only; production still needs reliable content geometry.
    separator = np.asarray(image.crop((0, template.body_top - 1, width, template.body_top)).convert('RGBA'), dtype=np.int16)
    if (np.any(separator[:, :, 3] != 255)
            or np.any(np.abs(separator[:, :, :3] - np.rint(background * .9)) > 1)):
        return keep('unverified_body_boundary')

    # This is a manually annotated local reference, not a generic corner exclusion.
    size = template.corner_size
    corners = [([0, height - size, size, size], (0, height - size)),
               ([width - size, height - size, size, size], (template.image.width - size, height - size))]
    cx, cy, cw, ch = template.control_bounds
    control_bounds = [width - (template.image.width - cx), cy, cw, ch]
    reference_control = np.asarray(template.image.crop((cx, cy, cx + cw, cy + ch)).convert('RGBA'), dtype=np.int16)
    reference_mask = np.any(reference_control[:, :, :3] != template.background, axis=2)
    # The exact interior includes the label. Only the 2-pixel antialias fringe gets a tolerance.
    padded = np.pad(reference_mask, 2)
    interior = np.logical_and.reduce([padded[y:y + ch, x:x + cw] for y in range(5) for x in range(5)])
    control_matches = False
    if set(titles) == {'起始页'} and any(r['bounds'] == control_bounds for r in analysis['regions']):
        x, y, w, h = control_bounds
        pixels = np.asarray(image.crop((x, y, x + w, y + h)).convert('RGBA'), dtype=np.int16)
        mask = np.any(pixels[:, :, :3] != background, axis=2)
        control_matches = (np.array_equal(pixels[:, :, 3], reference_control[:, :, 3])
                           and np.array_equal(mask, reference_mask)
                           and np.array_equal(pixels[interior], reference_control[interior])
                           and np.max(np.abs(pixels[reference_mask] - reference_control[reference_mask])) <= 4)
    explained = []
    for region in analysis['regions']:
        x, y, w, h = region['bounds']
        pixels = np.asarray(image.crop((x, y, x + w, y + h)).convert('RGBA'), dtype=np.int16)
        kind = None
        for bounds, (rx, ry) in corners:
            if region['bounds'] != bounds:
                continue
            alpha = pixels[:, :, 3]
            reference_alpha = np.asarray(template.image.crop((rx, ry, rx + size, ry + size)).getchannel('A'))
            # Quantized RGB in a translucent pixel may be unstable; compare its displayed contribution.
            actual = np.rint(pixels[:, :, :3] * (alpha[:, :, None] / 255))
            expected = np.rint(background * (alpha[:, :, None] / 255))
            known = np.zeros((h, w), dtype=bool)
            if control_matches:
                ex, ey, ew, eh = control_bounds
                x0, y0, x1, y1 = max(x, ex), max(y, ey), min(x + w, ex + ew), min(y + h, ey + eh)
                if x1 > x0 and y1 > y0:
                    known[y0 - y:y1 - y, x0 - x:x1 - x] = reference_mask[y0 - ey:y1 - ey, x0 - ex:x1 - ex]
            if (np.array_equal(alpha, reference_alpha)
                    and np.all(pixels[:, :, :3][(alpha == 255) & ~known] == background)
                    and np.all(np.abs(actual - expected)[~known] <= 2)):
                kind = 'window_corner'
        if region['bounds'] == control_bounds and control_matches:
            kind = 'start_page_edit_control'
        if kind is None:
            return keep('unexplained_region')
        explained.append({'bounds': region['bounds'], 'kind': kind})
    return {'decision': 'empty_browser', 'reason': 'all_residuals_explained', 'explained': explained}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('analysis', type=Path)
    parser.add_argument('metadata', type=Path)
    parser.add_argument('template', type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    analyses = {x['sample']: x for x in map(json.loads, args.analysis.read_text().splitlines())}
    metadata = json.loads(args.metadata.read_text())
    spec = json.loads(args.template.read_text())
    with Image.open(spec['path']) as source:
        template = Template(source.convert('RGBA'), spec['bodyTop'], tuple(spec['controlBounds']),
                            spec['cornerSize'], tuple(spec['backgroundRGB']))
    for sample in manifest:
        records = metadata.get(sample['sample'], [])
        with Image.open(sample['path']) as picture:
            result = classify(picture, analyses[sample['sample']], sample['contentBounds'],
                              [x['bundle_id'] for x in records], [x['window_title'] for x in records], template)
        print(json.dumps({'sample': sample['sample'], **result}, ensure_ascii=False))


if __name__ == '__main__':
    main()
