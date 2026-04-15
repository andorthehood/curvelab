# TODO 19 — rebuildCache: duplicated MainActor restoration block

## Location
`curvelab/ViewModels/ImageViewModel.swift` — `rebuildCache(invert:)`

## Problem
`rebuildCache` has two branches — a fast path (buffer already cached, only histogram needs
computing) and a slow path (full render + histogram).  Both branches end with a nearly
identical `MainActor.run` block that restores the same set of properties and calls
`updatePreview()`, `isLoading = false`, and `saveState()`:

```swift
self.cachedImage  = cached
self.histogram    = histData
self.cropState    = ...
self.cacheVersion = UUID()
self.updatePreview()
self.isLoading    = false
self.saveState()
```

Adding a new property to this restoration (e.g. a new published flag) requires updating
both branches.  The same pattern also appears in `applyCrop()` and `resetCrop()`.

## Fix
Extract a private helper:

```swift
private func finishCacheRebuild(cached: CIImage?, histData: HistogramData?, hasCrop: Bool) {
    cachedImage  = cached
    histogram    = histData
    cropState    = ...
    cacheVersion = UUID()
    updatePreview()
    isLoading    = false
    saveState()
}
```

All four call sites (`rebuildCache` fast path, `rebuildCache` slow path, `applyCrop`,
`resetCrop`) replace their restoration blocks with a single call to this helper.
