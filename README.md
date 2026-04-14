# CurveLab

A macOS app for editing tone curves on 48-bit DNG files from film scanners, with real-time preview and JPG export.

![Platform](https://img.shields.io/badge/platform-macOS%2014.7%2B-lightgray)
![Swift](https://img.shields.io/badge/swift-5-orange)

## Features

- **Import 48-bit DNG files** from film scanners via `CIRAWFilter` — no automatic tone mapping or gamut correction applied, preserving the flat scan data
- **Curve editor** with composite RGB curve and individual R, G, B channel curves
- **Natural cubic spline** interpolation for smooth curves (C² continuity)
- **Input histogram** displayed behind the curve, aligned to the input axis so you can place points based on where the image data sits
- **Output histogram** showing the result after curves are applied, updated live as you drag
- **Real-time GPU preview** via Metal and `CIColorCube` 3D LUT — no CPU roundtrips
- **Rotate** the image 90° left or right
- **Export to JPG** at full resolution in sRGB, quality 0.92

## Usage

| Action | How |
|--------|-----|
| Import DNG | Toolbar → Import DNG (or drag onto window) |
| Add curve point | Click and drag anywhere on the curve |
| Move point | Drag any control point |
| Delete point | Double-click a control point |
| Switch channel | RGB / R / G / B segmented picker |
| Rotate | Toolbar → Rotate Left / Rotate Right |
| Reset curves | Toolbar → Reset Curves |
| Export | Toolbar → Export JPG |

## Architecture

```
curvelab/
  Models/
    CurveModel.swift        — control points, per-channel curves, channel selection
    HistogramData.swift     — histogram computation and curve remapping
  ViewModels/
    ImageViewModel.swift    — import, preview pipeline, export, rotation
  Views/
    ImagePreviewView.swift  — MTKView wrapper for GPU rendering
    CurveEditorView.swift   — Canvas with draggable spline handles
    ChannelPickerView.swift — RGB/R/G/B segmented picker
    ResultHistogramView.swift — output histogram display
  Utilities/
    DNGLoader.swift         — CIRAWFilter-based DNG loading
    CubicSpline.swift       — natural cubic spline (Thomas algorithm)
    LUTGenerator.swift      — builds 33³ CIColorCube LUT from curves
```

## Requirements

- macOS 14.7+
- Xcode 15+

## Building

Open `curvelab.xcodeproj` in Xcode and run.
