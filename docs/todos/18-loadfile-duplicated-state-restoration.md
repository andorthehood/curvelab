# TODO 18 — loadFile: duplicated state restoration block

## Location
`curvelab/ViewModels/ImageViewModel.swift` — `loadFile(url:)`

## Problem
The fast path (buffer + histogram both cached) and the slow path (full DNG decode) each
assign the same ~15 properties and then call `updatePreview()` and `saveState()`:

```
originalImage, cachedImage, rotationAngle, isNegative, appliedCropRect,
histogram, cropState, showCropOverlay, cropAspectRatio, inputBlackPoint,
inputWhitePoint, curves, suppressCacheRebuild, undoStack, lastSavedData,
canUndo, cacheVersion
```

The two blocks are nearly identical.  Adding a new piece of state (e.g. a new UI flag or
sidecar field) requires updating both branches.  One branch is easy to miss, causing a
subtle difference in behaviour between cached and uncached loads.

## Fix
Extract a private helper:

```swift
private func finishLoad(
    cachedImage: CIImage?,
    histogram:   HistogramData?,
    rotation:    Double,
    isNegative:  Bool,
    cropRect:    CGRect?,
    state:       EditingState?,
    original:    CIImage?
) { ... }
```

Both branches call this helper.  The slow path wraps the call inside its `MainActor.run`
block; the fast path calls it directly (already on the main actor).
