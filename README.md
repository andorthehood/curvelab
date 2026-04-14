# CurveLab

A macOS app for editing tone curves on 48-bit DNG files from film scanners, with real-time preview and JPG export.

![Platform](https://img.shields.io/badge/platform-macOS%2014.7%2B-lightgray)
![Swift](https://img.shields.io/badge/swift-5-orange)

## Features

### Import & decode
- **Import 48-bit DNG files** from film scanners via `CIRAWFilter` — no automatic tone mapping or gamut correction applied, preserving the flat scan data
- **Negative inversion** — one-click toggle to invert the image before caching, so histograms and curves work on the positive image directly; designed for C-41 colour negatives
- **Recent files bar** — horizontal scrollable strip at the bottom of the window showing previously opened files as thumbnails; click to reopen, right-click to remove; active file shows a live thumbnail updated as you edit

### Levels
- **Input levels** — compact histogram strip with draggable black-point and white-point handles; shades the clipped regions outside the active range
- **Regular black-point handle** (bottom) — moves `inputBlackPoint` only; curves are untouched
- **Linked black-point handle** (top) — moves `inputBlackPoint` while simultaneously remapping curve control points so every pixel's output value is mathematically preserved; capped at the active curve's leftmost point to prevent data loss
- **After-levels histogram** — intermediate histogram showing the image state after levels but before curves, so each tool in the pipeline can be evaluated independently

### Curves
- **Composite RGB curve and individual R, G, B channel curves** — channel picker switches between them
- **Natural cubic spline** interpolation (C² continuity, Thomas algorithm)
- **Add point** — click and drag anywhere on the curve; the new point snaps to the spline at that x position
- **Delete point** — double-click any control point
- **Shift strip** — narrow draggable bar above the curve canvas; shows the active curve's point span as a coloured segment; drag left/right to shift all control points horizontally together; bypasses neighbour-clamping so relative spacing is preserved; dragging past the edge and back restores original positions
- **Input histogram** displayed behind the curve editor, showing the post-levels pixel distribution aligned to the curve's input axis
- **Output histogram** showing rendered pixel values after curves are applied, updated live

### Black-point tools
- **Absorb BP** — folds the active curve channel's leftmost control-point shift into `inputBlackPoint` in one step, then stretches all curves back to full width; output is mathematically unchanged; uses active channel as the reference (RGB selection adjusts the RGB curve; R/G/B selection adjusts all three per-channel curves)
- **Linked black-point handle** — the real-time, draggable version of Absorb BP; see above under Levels

### Crop
- **Crop overlay** — toggleable overlay with 8 draggable handles (4 corners + 4 edge midpoints) and a rule-of-thirds grid shown while dragging
- **Body drag** — drag inside the crop box to reposition it without resizing
- **Aspect ratio lock** — 7 presets: Free, 1:1, 2:3, 3:2, 4:5, 5:4, 16:9
- **Apply Crop** — bakes the crop region into the float32 cache and recomputes the histogram
- **Reset Crop** — restores the full original at the current rotation

### Presets
- **Preset panel** — fixed column on the right showing saved presets as thumbnails rendered against the current image
- **Save preset** — captures the current state of negative flag, input levels, and all curves (excludes crop and rotation)
- **Apply preset** — click any thumbnail to apply its settings; current edits are not modified retroactively
- **Delete preset** — right-click any thumbnail
- **Global persistence** — presets are stored in `~/Library/Application Support/CurveLab/presets.json` and shared across sessions

### Other
- **Rotate** the image 90° left or right; rotation rebuilds the float32 cache
- **Resizable sidebar** — drag the divider between the image and the editing panel
- **Non-destructive sidecar** — all edits (curves, levels, crop, rotation, negative flag) are auto-saved to a `.curvelab` JSON file next to the DNG and restored on next import
- **Export to JPG** at full resolution with correct sRGB gamma encoding; optional linear export for compositing tools

## Usage

| Action | How |
|--------|-----|
| Import DNG | Toolbar → Import DNG |
| Reopen recent file | Click thumbnail in the bottom bar |
| Invert negative | "Negative" checkbox |
| Adjust input levels | Drag black/white point handles on the levels strip |
| Move black point with curves preserved | Drag the top (linked) handle on the levels strip |
| Add curve point | Click and drag anywhere on the curve |
| Move curve point | Drag any control point |
| Delete curve point | Double-click a control point |
| Shift all points horizontally | Drag the shift strip above the curve canvas |
| Switch channel | RGB / R / G / B picker |
| Absorb curve black point into levels | Select reference channel → "Absorb BP" button |
| Show crop overlay | "Show Crop" checkbox |
| Lock crop aspect ratio | Select a ratio preset button |
| Apply / reset crop | "Apply Crop" / "Reset Crop" buttons |
| Rotate | Toolbar → Rotate Left / Rotate Right |
| Reset curves and levels | Toolbar → Reset Curves |
| Save preset | "+" button in the Presets column |
| Apply preset | Click any preset thumbnail |
| Delete preset | Right-click preset thumbnail → Delete |
| Linear export | "Linear Export" checkbox |
| Export | Toolbar → Export JPG |

## Architecture

```
curvelab/
  Models/
    CurveModel.swift          — control points, shared CodableCurves type, channel curves,
                                stretchFromBlackPoint, channel selection
    CropState.swift           — crop rect (CIImage pixel space) and active flag
    EditingState.swift        — Codable sidecar format; save/load all editing decisions
    HistogramData.swift       — histogram computation from rendered pixels
    Preset.swift              — Codable preset (levels + curves, no crop/rotation)
    PresetStore.swift         — global preset persistence to Application Support
    RecentFile.swift          — recent file entry (URL + thumbnail reference)
    RecentFilesStore.swift    — recent files list + JPEG thumbnail storage
  ViewModels/
    ImageViewModel.swift      — import, float32 pixel cache, preview pipeline, rotation,
                                inversion, crop, levels, presets, thumbnail rendering,
                                black-point tools, sidecar save/load, export
  Views/
    ImagePreviewView.swift    — MTKView wrapper (bgra8Unorm, linearSRGB working space)
    CropOverlayView.swift     — scrims, border, rule-of-thirds grid, drag handles,
                                aspect ratio enforcement, body drag
    CurveEditorView.swift     — Canvas with draggable spline handles, histogram overlay,
                                ⌥-drag horizontal shift
    ChannelPickerView.swift   — RGB/R/G/B segmented picker
    LevelsView.swift          — histogram strip with regular and linked black-point handles,
                                white-point handle, clipped-region shading
    ResultHistogramView.swift — output histogram display (after-levels and final output)
    PresetsView.swift         — preset thumbnail column with add/delete
    RecentFilesView.swift     — horizontal recent-files bar with live active thumbnail
  Utilities/
    DNGLoader.swift           — CIRAWFilter-based DNG loading
    CubicSpline.swift         — natural cubic spline (Thomas algorithm)
    LUTGenerator.swift        — builds 33³ CIColorCube LUT from levels + curves;
                                CurveModel and ChannelCurve overloads for background threads
```

## Preview pipeline

```
DNG file
  → CIRAWFilter (decode once, no tone mapping)
  → optional CIColorInvert (negative toggle)
  → optional crop + normalise origin
  → CVPixelBuffer (float32, extendedLinearSRGB)  ← cached in memory
        ↓ on every levels or curve change
  → CIColorCube 3D LUT (GPU, 33³ entries)
        step 1 — input levels remap:
                 t' = clamp((t − blackPoint) / (whitePoint − blackPoint), 0, 1)
        step 2 — RGB composite curve
        step 3 — per-channel R / G / B curves
  → MTKView (Metal, bgra8Unorm, workingColorSpace: linearSRGB → sRGB)
```

The LUT is rebuilt on the CPU whenever levels or curves change and applied on the GPU in a single pass. The float32 cache is only rebuilt on rotation, inversion, or crop changes. The `.curvelab` sidecar is written automatically after every edit.

## Export pipeline

```
previewImage (lazy CIImage — LUT applied to cache)
  → CIContext (workingColorSpace: linearSRGB)
  → createCGImage (colorSpace: sRGB or linearSRGB)
  → CGImageDestination → JPEG (quality 0.92)
```

## Further reading

- [`docs/pipeline.md`](docs/pipeline.md) — detailed pipeline diagram with cache-rebuild and LUT-rebuild trigger tables
- [`docs/absorb-black-point.md`](docs/absorb-black-point.md) — technical explanation of the Absorb BP operation with proof of output equivalence
- [`docs/linked-black-point.md`](docs/linked-black-point.md) — technical explanation of the linked black-point handle, its cap, and its relationship to Absorb BP
- [`docs/curve-shift-strip.md`](docs/curve-shift-strip.md) — how the shift strip works, including the start-captured delta algorithm and jump-back behaviour

## Requirements

- macOS 14.7+
- Xcode 15+

## Building

Open `curvelab.xcodeproj` in Xcode and run.
