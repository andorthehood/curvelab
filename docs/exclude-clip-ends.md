# Exclude Clip Ends

## What it does

The "Exclude clip ends" checkbox re-normalises every histogram in the UI so that
the first bin (value 0) and the last bin (value 255) are excluded from the peak
calculation and zeroed out for display.  All four histograms are affected:

- Input levels histogram (behind the black/white-point handles)
- After-levels histogram
- Curve editor input histogram (shown behind the spline)
- Output histogram

## Why it exists

After setting input levels, any pixel whose raw value falls below the black point
is clamped to 0, and any pixel above the white point is clamped to 1.  These
clamped pixels accumulate in bin 0 and bin 255, often as a very large spike.

Because each histogram is normalised so its tallest bar reaches full height, a
dominant clipping spike at either end causes every other bar to be rendered at a
fraction of the available height — sometimes so small that the tonal distribution
across the rest of the range is essentially invisible.

The checkbox removes the spikes from consideration so the interior distribution
fills the full height and can be read clearly.

## Algorithm

The transformation is implemented as a computed property on `HistogramData`:

```
withClipEndsExcluded: HistogramData
```

For each channel (R, G, B, luminance):

1. **Zero the endpoints** — set `bins[0] = 0` and `bins[255] = 0`.
2. **Find the new peak** — `interiorMax = max(bins[1 … 254])`.
3. **Re-normalise** — divide every bin by `interiorMax`, capping at 1.0.

```
stripped[i] = bins[i] / interiorMax   for i in 1…254
stripped[0] = 0
stripped[255] = 0
```

The raw counts (`rawRed`, `rawGreen`, `rawBlue`) stored on `HistogramData` are
stripped and re-scaled in parallel so the histogram can still be remapped through
curves correctly when used as an intermediate (after-levels) histogram.

Luminance is derived from the pre-normalised luminance bins rather than from the
raw channel counts, so it is stripped and re-normalised independently using the
same two-step process.

## What is hidden

Clipped pixels are not shown in the histogram when this mode is active.  The
clipping shading overlaid on the levels strip (the dark overlay outside the
black/white-point handles) continues to show the clipped regions on the input
axis regardless of the toggle, so the extent of clipping remains visible even
when the spikes are excluded from the histogram.

## Scope and persistence

The toggle is a per-session `@State` variable on `ContentView`.  It is not
persisted to the `.curvelab` sidecar and resets to off when the app is relaunched.
It has no effect on export — the export pipeline operates on the raw float32 cache
and LUT, which are unaffected by histogram display settings.
