# Move output histogram computation to ViewModel

`ContentView.swift:41` calls `histogram.remapped(through:)` directly inside SwiftUI's `body`,
which means it recomputes the full output histogram on every SwiftUI render pass — including
renders unrelated to curve changes.

## Fix

Add a `@Published var outputHistogram: HistogramData?` property to `ImageViewModel` and
compute it inside `updatePreview()` alongside `previewImage`. `ContentView` then just reads
the published value instead of doing work in `body`.
