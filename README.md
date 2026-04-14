# CurveLab

A macOS app for editing tone curves on 48-bit DNG files from film scanners, with real-time preview and JPG export.

![Platform](https://img.shields.io/badge/platform-macOS%2014.7%2B-lightgray)
![Swift](https://img.shields.io/badge/swift-5-orange)

## Features

- **Import 48-bit DNG files** from film scanners via `CIRAWFilter` — no automatic tone mapping or gamut correction applied, preserving the flat scan data
- **Negative inversion** — one-click toggle to invert the image before caching, so histograms and curves work on the positive image directly; designed for C-41 colour negatives
- **Curve editor** with composite RGB curve and individual R, G, B channel curves
- **Natural cubic spline** interpolation for smooth curves (C² continuity)
- **Input histogram** displayed behind the curve, aligned to the input axis so you can place points based on where the image data sits
- **Output histogram** showing the actual rendered pixel values after curves are applied, updated live as you drag
- **Real-time GPU preview** via Metal and `CIColorCube` 3D LUT — no CPU roundtrips on every curve change
- **Float32 processing throughout** — DNG is decoded into a `CVPixelBuffer` (128-bit RGBA float) and all curve calculations, LUT application, and rendering operate at full 32-bit float precision; no precision loss until final 8-bit JPG export
- **Crop box** — toggleable overlay with 8 draggable handles; Apply Crop bakes the region into the float32 cache and recomputes the histogram; Reset Crop restores the full original
- **Rotate** the image 90° left or right; rotation rebuilds the cache, curves remain live
- **Non-destructive sidecar** — all edits (curves, crop, rotation, negative flag) are auto-saved to a `.curvelab` JSON file next to the DNG and restored on next import
- **Export to JPG** at full resolution with correct sRGB gamma encoding (preview matches export); optional linear export for compositing tools

## Usage

| Action | How |
|--------|-----|
| Import DNG | Toolbar → Import DNG |
| Invert negative | "Negative" checkbox in the right panel |
| Add curve point | Click and drag anywhere on the curve |
| Move point | Drag any control point |
| Delete point | Double-click a control point |
| Switch channel | RGB / R / G / B segmented picker |
| Show crop overlay | "Show Crop" checkbox in the right panel |
| Apply / reset crop | "Apply Crop" / "Reset Crop" buttons |
| Rotate | Toolbar → Rotate Left / Rotate Right |
| Reset curves | Toolbar → Reset Curves |
| Linear export | "Linear Export" checkbox in the right panel |
| Export | Toolbar → Export JPG |

## Architecture

```
curvelab/
  Models/
    CurveModel.swift          — control points, per-channel curves, channel selection
    CropState.swift           — crop rect (CIImage pixel space) and active flag
    EditingState.swift        — Codable sidecar format; save/load all editing decisions
    HistogramData.swift       — histogram computation from rendered pixels
  ViewModels/
    ImageViewModel.swift      — import, float32 pixel cache, preview pipeline,
                                rotation, inversion, crop, sidecar save/load, export
  Views/
    ImagePreviewView.swift    — MTKView wrapper (bgra8Unorm, linearSRGB working space)
    CropOverlayView.swift     — scrims, border, rule-of-thirds grid, drag handles
    CurveEditorView.swift     — Canvas with draggable spline handles and histogram overlay
    ChannelPickerView.swift   — RGB/R/G/B segmented picker
    ResultHistogramView.swift — output histogram display
  Utilities/
    DNGLoader.swift           — CIRAWFilter-based DNG loading
    CubicSpline.swift         — natural cubic spline (Thomas algorithm)
    LUTGenerator.swift        — builds 33³ CIColorCube LUT from curves
```

## Preview pipeline

```
DNG file
  → CIRAWFilter (decode once, no tone mapping)
  → optional CIColorInvert (negative toggle)
  → optional crop + normalise origin
  → CVPixelBuffer (float32, extendedLinearSRGB)  ← cached in memory
        ↓ on every curve change
  → CIColorCube 3D LUT (GPU, 33³ entries)
  → MTKView (Metal, bgra8Unorm, workingColorSpace: linearSRGB → sRGB)
```

On rotate, the cache is rebuilt from the original decoded image — curves and crop state are preserved. The `.curvelab` sidecar is written automatically after every edit.

## Export pipeline

```
previewImage (lazy CIImage — LUT applied to cache)
  → CIContext (workingColorSpace: linearSRGB)
  → createCGImage (colorSpace: sRGB or linearSRGB)
  → CGImageDestination → JPEG (quality 0.92)
```

## Requirements

- macOS 14.7+
- Xcode 15+

## Building

Open `curvelab.xcodeproj` in Xcode and run.
