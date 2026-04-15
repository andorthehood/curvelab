# 21 — Derive `levelsHistogram` and `outputHistogram` instead of walking pixels every frame

## Problem

The app has three histograms, handled with three different strategies, and two
of them are needlessly expensive:

| name | stage | cost per frame | storage |
|---|---|---|---|
| `result.histogram` | pre-levels (raw buffer) | **once per buffer**, cached by `RenderPipeline` | inside `RenderResult` |
| `levelsHistogram` | post-levels, pre-curves | **pixel walk every ~16 ms during curve drags** | `@Published` on `ImageViewModel` |
| `outputHistogram` | post-levels, post-curves | **pixel walk every ~16 ms during curve drags** | `@Published` on `ImageViewModel` |

Each pixel-walk call scales the image to 1024 px, renders a bitmap, and
iterates every byte to populate 256 bins. `updatePreview()` launches a
`Task.detached` on every curve frame that does this twice, then writes the
results back to `MainActor` without any generation guard — a slow frame can
finish after a fast one and overwrite newer histograms.

## The tell

`HistogramData.remapped(through: CurveModel)` already exists (at
`curvelab/Models/HistogramData.swift:108`) with the doc comment
*"Remap this histogram through the given curves to produce the output
histogram."* It is called from **nowhere** in the app. Someone intended to
derive the output histogram by running each bin of `result.histogram`
through the curve splines — a pure 256-iteration loop, no pixel touch —
but never wired it up. The levels-remap variant was never even written.

Fixing this wires up the existing-but-dead helper and adds its missing sibling.

## Proposed change

### A. Add a levels-remap variant to `HistogramData`

```swift
/// Remaps every bin through the input-levels transform
///   t' = clamp((t - blackPoint) / (whitePoint - blackPoint), 0, 1)
/// producing a post-levels histogram. Pure CPU, no pixel data.
func remapped(throughLevels blackPoint: Double, whitePoint: Double) -> HistogramData
```

Same structural pattern as the existing `remapped(through: CurveModel)`:
for each source bin `i`, compute the output bin index, accumulate
`rawRed[i] / rawGreen[i] / rawBlue[i]` into it, then normalise and
recompute luminance. ~30 lines.

### B. Derive both histograms inside `updatePreview()`

Replace the pixel-walking block in
`curvelab/ViewModels/ImageViewModel.swift:224-258`:

```swift
// BEFORE — lines 235-257
let levelsOnly = LUTGenerator.applyFilter(to: cachedImage, curves: CurveModel(),
                                          blackPoint: inputBlackPoint, whitePoint: inputWhitePoint)
let context = ciContext
Task.detached {
    async let lvlHist = HistogramData.compute(from: levelsOnly, context: context)
    async let outHist = HistogramData.compute(from: preview, context: context)
    // … thumbnail rendering …
    let (lv, out) = await (lvlHist, outHist)
    await MainActor.run {
        self.levelsHistogram         = lv
        self.outputHistogram         = out
        self.activeFileLiveThumbnail = thumbCG
    }
}
```

With synchronous derivation from `result.histogram`:

```swift
// AFTER — sketch
let source = result?.histogram
let lvl    = source?.remapped(throughLevels: inputBlackPoint, whitePoint: inputWhitePoint)
levelsHistogram = lvl
outputHistogram = lvl?.remapped(through: curves)

// Thumbnail still needs Task.detached + CIContext — keep that block,
// but strip the two HistogramData.compute calls and the levelsOnly build.
```

The thumbnail render stays async because `createCGImage` is genuinely
expensive and doesn't belong on the main actor. But it no longer carries
the two histograms with it.

### C. Delete the orphaned `levelsOnly` LUT build

The second `LUTGenerator.applyFilter(… curves: CurveModel(), …)` call
exists only to feed the now-removed `HistogramData.compute`. Delete it.

## Why this is safe

- `levelsHistogram` and `outputHistogram` stay `@Published` — existing
  reactivity in `ContentView`, `LevelsView`, `CurveEditorView`, and
  `ResultHistogramView` is unchanged. Only the compute path is different.
- No external API changes: the `HistogramData` struct's shape doesn't
  change; one new method is added, one is activated.
- The stale-writeback race on `levelsHistogram` / `outputHistogram`
  (same class as the former #12 on `cachedImage`) disappears because the
  two are now assigned synchronously from `updatePreview()` on MainActor.
  No `Task.detached → MainActor.run` round-trip for them.
- `result.histogram` is already computed from the post-rotate / post-invert /
  post-crop buffer, so the levels-then-curves remap composes correctly on
  top of it (same order as `LUTGenerator.applyFilter`, which does levels
  first and curves second). Double-check bin alignment: the existing
  `remapped(through:)` indexes into `rawRed[i]` with `i` as the pre-curves
  bin, which is exactly what a post-levels histogram provides.

## Numerical accuracy caveat

Bin-level remapping of a 256-bucket histogram through another 256-bucket
transform accumulates small rounding — each output bin is populated by
summing source bins whose remapped index lands in it, and the LUT
evaluation + `Int(x * 255)` floors can collapse neighbouring bins.

For display (a pixel-wide histogram strip, typically < 400 px on screen)
this is indistinguishable from the pixel-walked version. If a future
tool ever needs a *numerically exact* output histogram (batch QA,
clipping-pixel-count reports), it should re-walk the post-LUT pixels on
demand — not every frame. Call out this assumption in the new method's doc.

## Performance expectation

On a 24 MP image, the two `HistogramData.compute` calls dominate
`updatePreview()`'s detached work:

- Scale to 1024 px + `createCGImage` + pixel loop × 2 ≈ **several ms per frame** of CPU, much of it main-thread-adjacent via `Task.detached → MainActor.run`.
- Bin remap: two `for i in 0..<256` loops ≈ **tens of microseconds**, synchronous.

Expected wins:
- Curve drags stop heating the CPU on every frame.
- The thumbnail `Task.detached` becomes ~50% smaller (one output, not three).
- One `@Published` → MainActor writeback ordering footgun retired.

## Optional extension (do not bundle)

A more ambitious version deletes `@Published var levelsHistogram` and
`@Published var outputHistogram` entirely and makes the three histogram
views compute from `(result.histogram, inputBlackPoint, inputWhitePoint,
curves)` directly. That's cleaner architecturally (derived state stops
being stored state, matching the `result`-as-single-source-of-truth
pattern) but requires touching every consumer view and handling
`CurveModel`'s own `objectWillChange` for re-renders (today the
`updatePreview()` sink is what repaints the UI on curve drags).

Recommend: ship the compute-path change first (small, mechanical, obviously
safe). Reconsider the stored-vs-derived split as a follow-up only if the
view model is being trimmed for other reasons.

## Traps / context

1. **Order of operations.** `LUTGenerator.applyFilter` applies input levels
   first, then the RGB composite curve, then per-channel curves. The
   remap chain must match: `source → levels-remap → curves-remap`.
   `remapped(through:)` already applies composite then per-channel in the
   right order (see lines 123-125). Do not swap.
2. **`inputBlackPoint == inputWhitePoint`.** Guard against divide-by-zero
   in the levels remap — match the existing `LUTGenerator` behaviour
   (typically clamp range to a small epsilon).
3. **Clip-ends handling.** `withClipEndsExcluded` is applied view-side
   via `ContentView.hist(_:)`. Don't build that into the remap — it's a
   display concern keyed off a user toggle.
4. **`updatePreview()` is called from four places:** the curves
   `objectWillChange` sink (line 87), the levels debounce sink (line 111),
   `resetCurves()` (line 419), and `applyEditingState()` (line 592).
   All of them must end up with correct `levelsHistogram` / `outputHistogram`
   after the change. Since both are assigned synchronously at the top of
   the new `updatePreview()` body (before any `Task.detached`), this
   happens automatically.
5. **Nil source.** If `result == nil` (no file loaded), both derived
   histograms become `nil`, matching the current guard at line 225.

## Acceptance

- `HistogramData.remapped(throughLevels:whitePoint:)` added; unit-testable
  as a pure function.
- `HistogramData.remapped(through:)` now has at least one call site.
- `updatePreview()` contains no `HistogramData.compute` calls and no
  `LUTGenerator.applyFilter(… curves: CurveModel(), …)` call.
- `Task.detached` block inside `updatePreview()` produces only
  `activeFileLiveThumbnail`.
- Levels panel, curve-editor backdrop, "After levels" panel, and "Output"
  panel all render correctly on: file load, rotate, invert, crop,
  levels drag, curve drag, preset apply, undo.
- Build stays warning-free.

## Files

- `curvelab/Models/HistogramData.swift` — add the new method; existing
  `remapped(through:)` becomes live.
- `curvelab/ViewModels/ImageViewModel.swift:224-258` — rewrite
  `updatePreview()`.
- No view files change.
- No `RenderPipeline` / `RenderEngine` / `RenderCache` changes.
