# CropState minimum-size clamp can escape the image bounds

`CropState.clamped(to:)` intersects the crop rect with the image extent, but
then unconditionally expands width and height to `minimumSize`.

If the crop box is close to the right or top edge, that post-intersection
expansion can push `maxX` or `maxY` back outside the extent. The result is a
crop rect that is no longer actually clamped, which can produce invalid
overlay geometry and inconsistent crop behavior near the image edges.

## Fix

When enforcing the minimum size, re-anchor the rect so it still fits inside
the extent after resizing.

```swift
func clamped(to extent: CGRect) -> CropState {
    var r = rect.intersection(extent)

    let width = min(max(r.width, CropState.minimumSize), extent.width)
    let height = min(max(r.height, CropState.minimumSize), extent.height)

    r.size.width = width
    r.size.height = height
    r.origin.x = min(max(r.origin.x, extent.minX), extent.maxX - width)
    r.origin.y = min(max(r.origin.y, extent.minY), extent.maxY - height)

    return CropState(rect: r, isActive: isActive)
}
```
