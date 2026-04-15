# Histogram not recomputed after rotation

`rebuildCache()` rebuilds `cachedImage` from the rotated image but does not
recompute the histogram. The histogram shown after a rotation is left over
from the previous state.

Rotation preserves pixel values so the histogram is numerically correct, but
it is inconsistent — if the user rotates a cropped image the histogram no
longer reflects the current `cachedImage`.

## Fix

Compute `histData` inside `rebuildCache()` the same way `importImage()` does:

```swift
Task.detached {
    let cached = Self.renderToBuffer(rotated, context: context)
    let histData = cached.flatMap { HistogramData.compute(from: $0) }
    await MainActor.run {
        self.cachedImage = cached
        self.histogram = histData
        // ...
    }
}
```
