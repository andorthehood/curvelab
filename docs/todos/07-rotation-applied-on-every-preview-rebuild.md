# Rotation recalculated on every preview rebuild

`ImageViewModel.updatePreview()` calls `rotateImage()` on every single preview update —
including every curve drag. The rotation transform is reapplied to the full-resolution image
each time even though the rotation hasn't changed.

## Fix

When rotation changes, store the rotated original as a separate property
(e.g. `rotatedOriginalImage`) and apply curves on top of that. `updatePreview()` then only
needs to apply the LUT filter, not the rotation. Rotation only needs to be recalculated when
the user explicitly clicks rotate — not on every curve change.

```swift
// On rotate:
rotatedOriginalImage = rotate(originalImage)

// On updatePreview:
previewImage = LUTGenerator.applyFilter(to: rotatedOriginalImage, curves: curves)
```
