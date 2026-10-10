# Capture content analysis experiments

These tools are offline probes. They do not change capture preferences, write to the library, or decide which screenshots to delete.

The production `CapturedImage.prepare` path now offers an opt-in near-uniform filter at **98%**, using `CaptureContentAnalysis` with region analysis disabled. Window captures exclude the top 8.5% to match this corpus comparison; display captures use the entire image. The filter runs before PNG encoding and persistence and bypasses manual captures. The offline probe below retains its original 99% candidate threshold and region diagnostics.

`blank_capture_probe.py` retains the original color-ratio baselines and synthetic counterexamples. It requires Pillow.

`CaptureContentProbe.swift` runs the same native `CaptureContentAnalysis` implementation covered by the core tests:

```sh
mkdir -p build/blank-capture-regions
swiftc -O -swift-version 6 -parse-as-library \
  MyClip/Core/Capture/CaptureContentAnalysis.swift \
  Tests/Experiments/CaptureContentProbe.swift \
  -o build/blank-capture-regions/capture-content-probe
bash Scripts/test.sh core --filter CaptureContentAnalysisTests
build/blank-capture-regions/capture-content-probe /path/to/manifest.json > /path/to/results.jsonl
```

The manifest is a JSON array. Bounds are `[x, y, width, height]` in original image pixels, with the origin at the top left. Omit `contentBounds` to analyze the whole image. The detector never assumes a toolbar height or automatically excludes corners.

```json
[
  {
    "sample": "example",
    "path": "/absolute/path/to/screenshot.png",
    "contentBounds": [0, 80, 1280, 820]
  }
]
```

Each result is one JSON line:

- `not_candidate`: the near-background fraction is below 99%. Region analysis was not run; an empty region array here is not evidence of blankness.
- `candidate_with_regions`: a color candidate containing residual pixels. Region bounds, pixel counts and maximum differences identify what needs inspection. A single region or a single pixel is not discarded.
- `uniform_candidate`: no residual pixels were found. This describes visual uniformity only; an empty document or solid-color artwork can produce the same result.
- `unavailable`: decoding, geometry or the pixel budget prevented analysis. This must not become permission to discard an image.

The initial color test allows a maximum per-channel difference of 6/255 from the median background. The region pass uses every nonzero difference at the original resolution, including alpha differences. It performs eight-neighbour connected-component analysis without smoothing, downsampling, erosion, area thresholds, OCR or a browser-control whitelist.

Pixels are normalized to eight-bit sRGB before comparison. Transparency contributes `255 - alpha` to the difference, so a fully transparent image is not an opaque-background candidate. `not_candidate` does not establish that a screenshot is valid or that its page has finished loading.

At most 256 regions are returned. `regionsTruncated: true` explicitly marks incomplete region output. Images above 16,777,216 pixels and non-integral, empty or out-of-image content bounds return no analysis. These are resource and input limits, not image-quality judgments.

Private manifests, original image paths, replay results and diagnostic images belong under the ignored `build/` directory. Do not commit the user's screenshots or OCR output.

## Known Safari control experiment

`browser_empty_probe.py` tests a narrower hypothesis: whether every residual region can be explained by a manually reviewed Safari start-page control or a window corner. It requires Pillow and NumPy, consumes the native probe's results, and emits hypothetical decisions without deleting or changing anything.

```sh
python3 -m unittest discover -s Tests/Experiments -p test_browser_empty_probe.py -v
python3 Tests/Experiments/browser_empty_probe.py \
  /path/to/manifest.json /path/to/results.jsonl \
  /path/to/metadata.json /path/to/template.json > /path/to/decisions.jsonl
```

Metadata maps each sample ID to a list of `{ "bundle_id": "com.apple.Safari", "window_title": "起始页" }` records. The local template JSON supplies `path`, `bodyTop`, `controlBounds` (`[x, y, width, height]`), `cornerSize`, and `backgroundRGB`. It must reference a manually reviewed screenshot; no private template pixels are committed here.

This experiment is calibrated to the observed Chinese Safari layout, scale and light backgrounds. It verifies the expected body-divider pixels, right-edge control position, control silhouette and interior label, and corner alpha pattern. It does not ignore whole rectangles: overlapping control and corner bounds are checked with a verified control pixel mask. Two pixels of control antialias fringe allow a maximum difference of four color levels; the interior must match exactly. Translucent corner pixels allow two levels of rounding error in their premultiplied contribution, while unexplained opaque pixels must equal the background.

`empty_browser` means the offline hypothesis would filter this sample. Unsupported applications, geometry, color profiles, incomplete results, unfamiliar controls, or unexplained residuals produce `keep`. This is retrospective calibration, not independent validation or a general loading-state classifier. The divider guard catches the tested toolbar-height change, but does not replace reliable browser content geometry in a production implementation. See `docs/blank-capture-control-validation-2026-09-25.md` for measured results and limits.
