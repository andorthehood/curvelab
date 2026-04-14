# CurveLab Processing Pipeline

## Overview

The pipeline has two distinct phases with very different performance characteristics:

- **Cache-rebuild operations** — slow (tens to hundreds of ms). Change which pixels live in the float32 buffer. Triggered by rotation, negative toggle, and area crop.
- **LUT operations** — real-time (< 16 ms). Re-interpret the cached pixels on every frame without touching the buffer. Triggered by levels or curve changes.

```
Original DNG file (on disk)
       │
       ▼
  CIRAWFilter                     decode once, no tone mapping, no gamut correction
       │
       ▼
  CIColorInvert  ─ ─ ─ ─ ─ ─ ─   optional, controlled by isNegative toggle
       │
       ▼
  rotateImage()  ─ ─ ─ ─ ─ ─ ─   0 / 90 / 180 / 270°, resets appliedCropRect
       │
       ▼
  cropped(to: appliedCropRect)    spatial crop, normalises origin to (0, 0)
       │
       ▼
  renderToBuffer()
       │
       ▼
  CVPixelBuffer  ════════════════  cachedImage — 128-bit RGBA float32, extendedLinearSRGB
                                   stable in memory; never re-decoded unless the above changes
       │
       │   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ real-time from here down ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
       │
       ▼
  CIColorCube 3D LUT              33³ entries, built from levels + curves on CPU, applied on GPU
       │                          step 1 — input levels remap:
       │                            t' = clamp((t - blackPoint) / (whitePoint - blackPoint), 0, 1)
       │                          step 2 — RGB composite curve → per-channel R / G / B curves
       │                          order: RGB composite curve → per-channel R / G / B curves
       │
       ▼
  previewImage (lazy CIImage)
       │
       ▼
  MTKView (Metal)                 workingColorSpace: linearSRGB → colorSpace: sRGB
       │                          pixel format: bgra8Unorm (single gamma pass via CoreImage)
       ▼
  Screen

```

## Cache rebuild triggers

| Action | Rebuilds cache |
|--------|---------------|
| Import new file | ✓ (full decode) |
| Negative toggle | ✓ |
| Rotate left / right | ✓ (clears appliedCropRect) |
| Apply Crop | ✓ |
| Reset Crop | ✓ |

## Real-time (LUT) triggers

| Action | Rebuilds LUT |
|--------|-------------|
| Drag black-point handle | ✓ |
| Drag white-point handle | ✓ |
| Drag curve point | ✓ |
| Switch active channel | ✓ |

## Export path

```
previewImage (lazy CIImage — same as preview)
       │
       ▼
  CIContext (workingColorSpace: linearSRGB)
       │
       ▼
  createCGImage(colorSpace: sRGB)     non-linear export — gamma-encoded, correct for display/web
           or
  createCGImage(colorSpace: linearSRGB)   linear export — for compositing tools
       │
       ▼
  CGImageDestination → JPEG (quality 0.92)
```

## Sidecar (.curvelab)

All non-destructive editing decisions are serialised to a JSON sidecar next to the DNG and restored on next import:

```json
{
  "version": 1,
  "rotation": 90,
  "isNegative": true,
  "appliedCropRect": { "x": 120, "y": 80, "width": 3200, "height": 2100 },
  "inputBlackPoint": 0.12,
  "inputWhitePoint": 0.88,
  "curves": {
    "rgb":   { "points": [[0.0, 0.0], [0.5, 0.6], [1.0, 1.0]] },
    "red":   { "points": [[0.0, 0.0], [1.0, 1.0]] },
    "green": { "points": [[0.0, 0.0], [1.0, 1.0]] },
    "blue":  { "points": [[0.0, 0.0], [1.0, 1.0]] }
  }
}
```
