# applyCrop / resetCrop ignore rotation (bug)

`applyCrop()` always crops from `originalImage` (the un-rotated DNG), but
`cropState.rect` lives in the coordinate space of `cachedImage` — which may
have been rotated. After a rotation the two spaces don't match, so the crop
lands on the wrong region of the image.

`resetCrop()` has the same problem: it re-renders `originalImage` directly,
silently losing any rotation the user applied.

## Fix

Introduce a `rotatedOriginalImage: CIImage?` property that stores the
rotated-but-not-cropped image. Use it as the crop/reset source instead of
`originalImage`.

```swift
// On rotate (rebuildCache):
rotatedOriginalImage = rotated   // store before renderToBuffer

// applyCrop:
let source = rotatedOriginalImage ?? originalImage
let cropped = source.cropped(to: cropState.rect)

// resetCrop:
let source = rotatedOriginalImage ?? originalImage
let cached = Self.renderToBuffer(source, context: context)

// On import: clear rotatedOriginalImage
rotatedOriginalImage = nil
```
