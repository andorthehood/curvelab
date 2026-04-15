# imageSize is not reactive

`ImageViewModel.imageSize` is a plain computed property that reads from
`private var cachedImage`, which is not `@Published`. SwiftUI won't
re-evaluate it when `cachedImage` changes, so `CropOverlayView` can receive
stale dimensions after a rotation or crop.

## Fix

Either promote `cachedImage` to `@Published`:

```swift
@Published private var cachedImage: CIImage?
```

Or publish `imageSize` directly by updating it explicitly wherever
`cachedImage` is assigned, alongside `cropState`.
