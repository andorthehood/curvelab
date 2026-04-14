# Curve Shift Strip

## What it is

A narrow draggable bar sits directly above the curve canvas. It shows the active
curve's control-point span as a filled segment — coloured to match the active
channel (white for RGB, red/green/blue for per-channel). Dragging the strip left
or right shifts all control points on the active curve horizontally in unison,
without altering their vertical (output) positions or their relative spacing.

The strip width matches the canvas width, so a drag of N pixels corresponds to
exactly N/width in normalised curve space — the same units as the control points.

## Why it exists

Moving a cluster of control points that are tightly grouped near the left side of
the curve is otherwise cumbersome: each point must be dragged individually, and
neighbour-clamping (which prevents points from crossing each other) causes bunching
if you try to move them in the wrong order.

The shift strip bypasses neighbour-clamping entirely and moves all points as a
rigid body, making it easy to reposition the whole curve without distorting its shape.

## Visual indicator

The coloured segment spans from the leftmost to the rightmost control point's x
position, scaled to the strip's pixel width:

```
leftX  = leftmost.x  × stripWidth
rightX = rightmost.x × stripWidth
```

As you drag, both edges of the segment move together, giving immediate visual
feedback about where the curve sits on the input axis.

## Algorithm

The strip uses a **start-captured delta** approach rather than a per-frame
accumulation:

1. **On drag start** — snapshot all control point x positions into `shiftStartXs`:
   `shiftStartXs[point.id] = point.x` for every point on the active curve.

2. **On every drag frame** — compute the total delta from the *drag origin*:
   `deltaX = (location.x − startLocation.x) / stripWidth`
   Then restore each point to its captured start x and apply the delta:
   `point.x = clamp(shiftStartXs[point.id] + deltaX, 0, 1)`

3. **On drag end** — discard `shiftStartXs`.

Computing delta from the origin (not from the previous frame) means the operation
is path-independent: the result at any given cursor position is the same regardless
of how the cursor got there.

## Jump-back behaviour

Because points are always restored to their *start* x before the delta is applied,
dragging past an edge and then back recreates the original configuration exactly.

For example: if a point starts at x = 0.1 and you drag far enough left that it
clamps to x = 0, then drag rightward again until the delta is positive, the point
leaves 0 and moves right from 0.1 — not from 0. No shape distortion occurs at
the boundary.

This contrasts with a naive per-frame approach, where each frame's delta is added
to the *current* (already clamped) x, so points that hit the boundary can never
recover their pre-clamp spacing on the way back.

## Scope

The shift strip operates on the **active channel's curve only** — whichever channel
is selected in the channel picker (RGB, R, G, or B). Switching channels resets the
strip's visual span to the new active curve.
