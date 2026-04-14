# NSCursor stack grows unboundedly on hover

In `CropOverlayView`, `.onContinuousHover` calls `NSCursor.push()` on every
mouse-move event but only calls `NSCursor.pop()` once when the phase ends.
If the cursor kind changes while the mouse is moving (e.g. crossing from one
handle to another) each change pushes another entry onto the stack. A single
pop on `.ended` leaves stale entries behind and the original cursor is never
restored.

## Fix

Track the currently pushed cursor kind and only push/pop when it changes:

```swift
@State private var pushedCursorKind: HandleKind?? = nil  // nil = nothing pushed

.onContinuousHover { phase in
    switch phase {
    case .active(let location):
        let kind = nearestHandle(to: location, in: box)
        if kind != pushedCursorKind {
            if pushedCursorKind != nil { NSCursor.pop() }
            nsCursor(for: kind).push()
            pushedCursorKind = kind
        }
    case .ended:
        if pushedCursorKind != nil {
            NSCursor.pop()
            pushedCursorKind = nil
        }
    }
}
```
