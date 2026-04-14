# Double-click can accidentally delete a point during a fast drag

Because the tap and drag gestures run simultaneously, a fast drag (mousedown → tiny move →
mouseup → mousedown) can be misinterpreted as a double-click, triggering `onDoubleClick` and
deleting the point that was just being dragged.

## Fix

Guard `onDoubleClick` against firing when a drag is in progress by checking `draggingPointID`:

```swift
private func onDoubleClick(location: CGPoint, size: CGFloat, origin: CGPoint) {
    guard draggingPointID == nil else { return }
    // ... rest of handler
}
```
