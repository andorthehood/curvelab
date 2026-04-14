# Async cache rebuilds can apply stale results out of order

`ImageViewModel` starts image import and cache rebuild work with independent
`Task.detached` jobs. If the user triggers multiple expensive operations in
quick succession — for example rotate twice, or rotate while toggling
Negative — the older task can finish last and still write its stale
`cachedImage`, `histogram`, and `cropState` back to the main actor.

That makes the visible preview drift out of sync with the latest UI state:
the controls can say one thing while the image reflects an earlier rebuild.

## Fix

Track rebuild requests and ignore stale completions, or cancel the previous
task before starting a new one.

One simple approach is to keep a monotonically increasing generation token:

```swift
private var rebuildGeneration: Int = 0

private func rebuildCache(invert: Bool? = nil) {
    rebuildGeneration += 1
    let generation = rebuildGeneration
    // ...
    Task.detached {
        let cached = Self.renderToBuffer(prepared, context: context)
        let histData = cached.flatMap { HistogramData.compute(from: $0) }
        await MainActor.run {
            guard generation == self.rebuildGeneration else { return }
            self.cachedImage = cached
            self.histogram = histData
            self.cropState = cached.map { CropState.full(for: $0) }
                ?? CropState(rect: .zero, isActive: false)
            self.updatePreview()
            self.isLoading = false
        }
    }
}
```

An alternative is to store the current task handle and cancel it when a newer
rebuild starts.
