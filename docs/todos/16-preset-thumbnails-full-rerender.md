# 16 — Preset thumbnails re-render all on any change

## Problem

`renderThumbnails(for:)` always rebuilds every thumbnail from scratch. Two triggers:

1. **`store.presets.count` changes** (add or delete) — only the new preset needs a thumbnail; existing ones are unchanged.
2. **`cacheVersion` changes** (rotation, crop, import) — all thumbnails need rebuilding because the source image changed.

With many presets, trigger #1 wastes time re-rendering unchanged entries.

## Fix

Filter to only missing entries before rendering:

```swift
let toRender = presets.filter { presetThumbnails[$0.id] == nil }
```

On cache invalidation (trigger #2) clear `presetThumbnails` first so all are treated as missing:

```swift
// In each cacheVersion bump site, also clear thumbnails:
self.presetThumbnails = [:]
self.cacheVersion = UUID()
```

Then `renderThumbnails` only processes `toRender`, and existing thumbnails remain in the dict for presets that didn't change.
