# Linked Black Point

## What it does

The levels strip has two black-point handles:

- **Bottom handle (regular)** — moves `inputBlackPoint` only. The curve is untouched, so
  the tonal mapping changes and shadow detail is clipped.
- **Top handle (linked)** — moves `inputBlackPoint` AND simultaneously remaps the relevant
  curve control points so that every pixel's output value is mathematically preserved.
  The black point moves but the image looks identical.

The linked handle is the real-time, incremental counterpart to the one-shot
[Absorb BP](absorb-black-point.md) button. Where Absorb BP collapses an existing
curve black-point shift into levels in one action, the linked handle lets you set the
black point and have the curves adjust live as you drag.

## Which curves are adjusted

The pipeline is `levels → RGB composite curve → per-channel R/G/B curves`. Adjusting
both layers at once would double-apply the correction and darken the image, so only one
layer is modified — determined by the active channel selection:

| Active channel | Curves adjusted |
|---|---|
| RGB | RGB composite curve only |
| R, G, or B | All three per-channel curves (R, G, B) |

This matches the behaviour of Absorb BP and is consistent with how the channel picker
controls the rest of the curve editing workflow.

## Algorithm

Let `bp` be the current `inputBlackPoint`, `wp` be `inputWhitePoint`, and `newBP` be the
value the linked handle is dragged to.

**Step 1 — Compute the normalised increment**

The curves operate in post-levels space — their x axis is the output of the levels remap,
not the raw pixel value. The equivalent shift in that space is:

```
x0 = (newBP - bp) / (wp - bp)
```

Positive x0: black point moves right, curves compress leftward.
Negative x0: black point moves left, curves expand rightward (undo).

**Step 2 — Remap curve control points**

Every control point in the adjusted layer is remapped by:

```
x_new = (x - x0) / (1 - x0)
```

clamped to [0, 1]. This is applied to each point independently; the spline is then
re-evaluated from the updated control points on the next render.

**Step 3 — Update inputBlackPoint**

```
inputBlackPoint = newBP
```

The operation is applied incrementally at each drag frame. Because the formula is
multiplicative (not additive), applying it in small steps is path-independent — dragging
to 0.2 in one move produces the same result as dragging to 0.1 and then to 0.2.

## Proof of output equivalence

Let `s = (t - bp) / (wp - bp)` be the post-levels value for raw input `t`.

After the update, the new post-levels value for the same input is:

```
s' = (t - newBP) / (wp - newBP)
   = (t - newBP) / ((1 - x0)(wp - bp))
```

The remapped curve evaluates `curve_new(s') = curve_old(s' · (1 - x0) + x0)`:

```
s' · (1 - x0) + x0
  = (t - newBP) / (wp - bp) + x0
  = (t - bp - x0(wp - bp)) / (wp - bp) + x0
  = (t - bp) / (wp - bp) - x0 + x0
  = s  ✓
```

`curve_new` evaluated at `s'` equals `curve_old` evaluated at `s` for every input `t`.
The per-channel curves downstream are unchanged, so the final output is identical.

## Hard cap: the leftmost-point limit

Dragging the linked handle past the leftmost control point of the relevant curves would
push that point below x = 0, where it gets clamped. Once clamped, the relative black
point offset is lost and the curve shape is permanently altered relative to what the
user intended.

To prevent this, the handle's travel is capped at `linkedBlackPointMax`:

```
leftmostX = min(red.leftmost.x, green.leftmost.x, blue.leftmost.x)   // per-channel mode
          = rgb.leftmost.x                                             // RGB mode

linkedBlackPointMax = bp + leftmostX × (wp - bp)
```

At this exact cap value, x0 = leftmostX, which maps the leftmost control point to
exactly x = 0 after stretching — the furthest it can go without data loss. This is
equivalent to what Absorb BP does when applied from the same starting state.

`linkedBlackPointMax` is a live computed property. As the user drags and `inputBlackPoint`
increases, the cap recalculates — tightening as the leftmost point approaches 0. When
`leftmostX` reaches 0 (all black-point shift has been fully absorbed into levels), the
cap equals `inputBlackPoint` and the linked handle freezes in place.

## Relationship to Absorb BP

The two controls are mathematically equivalent operations at different granularities:

| | Absorb BP | Linked handle drag |
|---|---|---|
| Trigger | Button press | Real-time drag |
| x0 source | Active curve's leftmost x | Drag delta / levels range |
| Direction | Always positive (absorbs existing shift) | Bidirectional |
| Scope | Collapses the full existing shift in one step | Applies incrementally |
| Result | Leftmost point lands at exactly x = 0 | Leftmost point moves proportionally |

Absorb BP is the natural finishing step after using the linked handle: once you have
dialled in the black point with the linked handle, Absorb BP tidies the curve by snapping
its leftmost point back to x = 0 and updating the black point to match.
