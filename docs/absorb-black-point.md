# Absorb Black Point

## The problem it solves

A common film scan editing workflow is to set a per-channel black point by dragging the
leftmost control point of each curve channel to the right. For example:

```
Red   leftmost point: (0.18, 0.0)
Green leftmost point: (0.22, 0.0)
Blue  leftmost point: (0.28, 0.0)
```

This crushes all input values below those thresholds to black on each channel. It works,
but it leaves each curve occupying only a fraction of its available width — the red curve
operates across 82% of the range, green across 78%, blue across 72%. The usable portion
is cramped toward the right, making fine tonal adjustments harder to place and preview.

The input levels black point handle does the same job — it clips shadows to black via a
linear remap — but the two mechanisms are being used in parallel without either knowing
about the other.

## What the button does

"Absorb BP" consolidates the two mechanisms into one. It takes the per-channel curve
shifts and folds the most conservative one into the input levels black point, then
stretches all four curves back to their full width. The output is mathematically identical
— no pixel value changes.

## Algorithm

**Step 1 — Find reference x0**

Use the leftmost point x of whichever curve channel is currently active in the editor.
If the RGB composite channel is selected, its leftmost x is used; if R, G, or B is
selected, that channel's leftmost x is used.

```
x0 = activeChannel.leftmost.x
```

This gives explicit control: switch to the channel you want to align to, then press the
button. The button is disabled when the active channel's leftmost point is already at 0.

**Step 2 — Promote x0 into input levels**

The curves operate in post-levels space — their x axis represents the output of the levels
remap, not the raw pixel value. To find the raw input value that corresponds to x0
post-levels:

```
newBlackPoint = currentBlackPoint + x0 × (currentWhitePoint - currentBlackPoint)
```

This correctly handles the case where the levels black and white points have already been
adjusted from their defaults (0 and 1).

**Step 3 — Stretch all curves back to full width**

Every control point across all four curves (RGB, R, G, B) is remapped so that x0 maps to
0 and 1 maps to 1, expanding the usable range back to the full [0, 1] interval:

```
x_new = (x - x0) / (1 - x0)
```

Channels whose leftmost point was pulled further right than x0 will end up with their
leftmost point still slightly above 0 after the stretch — they retain their relative
black point difference and remain fully intact. The RGB composite curve, whose leftmost
point was at 0, simply has its remaining points shifted slightly left, which is
mathematically harmless for an identity or near-identity curve.

## Proof of output equivalence

Let `s = (t - bp) / (wp - bp)` be the post-levels value for raw input `t`, with the
original black point `bp` and white point `wp`. The original curve evaluates at `s`.

After absorbing, the new black point is `bp' = bp + x0 × (wp - bp)`, so:

```
s' = (t - bp') / (wp - bp')
   = (t - bp') / ((1 - x0)(wp - bp))
```

The stretched curve evaluates `curve_new(s') = curve_old(s' × (1 - x0) + x0)`:

```
s' × (1 - x0) + x0
  = (t - bp') / (wp - bp) + x0
  = (t - bp - x0(wp - bp)) / (wp - bp) + x0
  = (t - bp) / (wp - bp) - x0 + x0
  = s  ✓
```

The stretched curve evaluated at the new levels output equals the original curve evaluated
at the original levels output for every input value `t`.

## Example

Before:
```
inputBlackPoint = 0.0,  inputWhitePoint = 1.0
Red   curve points: [(0.18, 0.0), (0.55, 0.5), (1.0, 1.0)]
Green curve points: [(0.22, 0.0), (0.60, 0.5), (1.0, 1.0)]
Blue  curve points: [(0.28, 0.0), (0.65, 0.5), (1.0, 1.0)]
```

With Red active: x0 = 0.18

After (Red was the active channel):
```
inputBlackPoint = 0.18,  inputWhitePoint = 1.0
Red   curve points: [(0.00, 0.0), (0.45, 0.5), (1.0, 1.0)]
Green curve points: [(0.05, 0.0), (0.51, 0.5), (1.0, 1.0)]
Blue  curve points: [(0.12, 0.0), (0.57, 0.5), (1.0, 1.0)]
```

Red's leftmost point lands at 0 because it was the reference. Green and blue retain
their relative offsets (0.05 and 0.12), reflecting that they had slightly deeper black
points. All curves are substantially wider than before.

If Blue had been the active channel instead (x0 = 0.28), the black point would be set
to 0.28 and all curves stretched further — Red and Green's leftmost points would move
below 0 and clamp there, discarding their relative shadow detail.
