# 22 — Extract buffer analysis (histogram) out of `RenderPipeline`

## Problem

`RenderPipeline` currently does two conceptually different jobs:

1. **Render** — turn a `RenderConfig` + source image into a rendered buffer.
2. **Analyse** — compute a histogram from that buffer.

These live in one actor because the infrastructure (actor isolation,
generation counter, LRU cache) already exists for job 1, and bundling
job 2 in was easy. But histogram is a pure *derivation of the buffer*,
not part of producing it. Bundling them blurs the layer.

The inconsistency is visible in the app as it stands:

- `levelsHistogram` and `outputHistogram` are pure derivations (via
  `HistogramData.remapped(…)`) — computed outside the pipeline, not
  cached, no actor.
- The source `histogram` — which is *also* a pure derivation, just from
  the buffer instead of from another histogram — lives inside
  `RenderResult`, is cached by `RenderCache`, and is computed inside
  `RenderPipeline.render`.

Three derivations, two patterns. The source histogram is the outlier.

## Why this matters

Right now, `n = 1`: histogram is the only buffer-derived measurement in
the app. Bundling it reads as fine. The moment a **second** buffer
derivation appears — clipping maps, focus peaks, average luminance,
exposure stats, auto-levels source data, thumbnail pixel stats — the
current design forces an ugly choice:

- **Bundle it too** → `RenderResult` becomes a bag of unrelated things;
  `RenderPipeline` quietly stops being a render pipeline and becomes a
  "pipeline of things associated with a buffer."
- **Build a second pattern alongside** → now histogram lives in the
  pipeline while the new derivation lives somewhere else. Worse than
  either pure option.

Extracting *before* that trigger hits costs ~80 lines of churn and one
new file. Extracting *after* means migrating both derivations at once
while under feature pressure.

## Target architecture

```
┌──────────────────────────────────────────────────────────────┐
│ RenderPipeline (actor)                                        │
│   render(config, from:) async -> CIImage?                     │
│   owns: buffer LRU, original LRU, generation counter          │
│   no HistogramData import, no analysis concerns               │
└──────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ BufferAnalyzer (enum of static async funcs)                   │
│   histogram(for: CIImage, context:) async -> HistogramData?   │
│   (future: clippingMap, focusPeaks, averageLuminance, …)      │
└──────────────────────────────────────────────────────────────┘
```

Composition happens at the call site (the view model or its successor):

```swift
guard let image = await pipeline.render(config, from: original) else { return }
let hist = await BufferAnalyzer.histogram(for: image, context: ciContext)
self.result          = RenderResult(cachedImage: image, extent: image.extent)
self.sourceHistogram = hist
```

## Concrete change set

All paths are relative to the repo root.

### New

**`curvelab/Utilities/BufferAnalyzer.swift`** (new file)

```swift
import CoreImage

/// Pure buffer-derived measurements. Stateless; safe to call from any task.
/// Sibling of `RenderPipeline` — the pipeline renders, this analyses.
enum BufferAnalyzer {
    /// Pre-levels, pre-curves histogram of a rendered float32 buffer.
    /// Runs the pixel walk off-actor so callers can await without blocking.
    static func histogram(for buffer: CIImage,
                          context: CIContext) async -> HistogramData? {
        await Task.detached(priority: .userInitiated) {
            HistogramData.compute(from: buffer, context: context)
        }.value
    }
}
```

### Modified

**`curvelab/Models/RenderResult.swift`** — drop `histogram`:

```swift
// BEFORE
struct RenderResult {
    let cachedImage: CIImage
    let histogram: HistogramData
    let extent: CGRect
}

// AFTER
struct RenderResult {
    let cachedImage: CIImage
    let extent: CGRect
}
```

Update the doc comment — it currently says "plus its histogram."

**`curvelab/Utilities/RenderCache.swift`** — drop the `histogram` LRU
and its four accessor methods. `buffer` and `original` LRUs stay.

**`curvelab/Utilities/RenderPipeline.swift`** — drop the histogram
compute inside `render(_:from:)` and the fast-path histogram cache
lookup. `render` keeps its generation counter and supersession check
but now applies it to the buffer alone.

After this change, `RenderPipeline.swift` imports `CoreImage` only
(no model-layer imports), and `RenderResult` is effectively a struct
wrapper around `(CIImage, CGRect)`.

**`curvelab/ViewModels/ImageViewModel.swift`** — add
`@Published private(set) var sourceHistogram: HistogramData?` as the
sibling to `result`. Rewrite the three call sites that invoke the
pipeline (`loadFile`, `rebuildCache`, `applyCrop`, `resetCrop`) to
compose pipeline + analyzer:

```swift
guard let image = await pipeline.render(config, from: original) else { return }
let hist = await BufferAnalyzer.histogram(for: image, context: ciContext)
self.result          = RenderResult(cachedImage: image, extent: image.extent)
self.sourceHistogram = hist
// … rest of the existing writeback …
```

Update the derived getter:

```swift
var histogram: HistogramData? { sourceHistogram }    // was: result?.histogram
```

## Supersession: does the analyzer need its own generation counter?

**No.** The analyzer is stateless and called *after* the pipeline
returns a non-nil result. If another render supersedes during the
analyzer call, the second render will itself fire pipeline + analyzer
and write newer values. The worst case is the older analyzer finishing
second and overwriting the newer `sourceHistogram` — same class of
race as the old `levelsHistogram` / `outputHistogram` bug, with the
same fix: apply a supersession check at the call site.

Simplest solution: the view model holds a single `renderGeneration: Int`
counter bumped before each pipeline call, captured locally, and
checked before writing `result` / `sourceHistogram`:

```swift
renderGeneration += 1
let gen = renderGeneration
guard let image = await pipeline.render(config, from: original) else { return }
guard gen == renderGeneration else { return }
let hist = await BufferAnalyzer.histogram(for: image, context: ciContext)
guard gen == renderGeneration else { return }
self.result          = RenderResult(cachedImage: image, extent: image.extent)
self.sourceHistogram = hist
```

This mirrors what the pipeline already does internally, but at the
caller's level because two async steps now need to stay consistent.

## What this costs

- **Cache-hit latency** — a repeat config (rotate back, invert toggle
  back) previously returned cached buffer *and* cached histogram. Now
  it returns cached buffer; histogram is recomputed. At 1024 px
  downscale this is ~5–10 ms, off-actor. Unlikely to be noticeable; if
  profiling ever says otherwise, add a small `HistogramData` LRU keyed
  on `RenderConfig` *inside* `BufferAnalyzer`. Do not put it back in
  `RenderCache`.
- **One more `@Published`** on the view model (`sourceHistogram`
  separate from `result`). Mild regression on the "single source of
  truth" framing from the render-pipeline refactor — but the truth is
  that `RenderResult` was never really one thing; it was a buffer plus
  a measurement stapled on. Acknowledging that in the type system is
  more honest than hiding it.

## What it gains

- `RenderPipeline` and `RenderCache` stop importing / depending on
  `HistogramData`. Their public surface matches their names.
- `RenderResult` becomes what it claims to be: a render result.
- Adding the second buffer derivation (when it happens) is a
  file-local change to `BufferAnalyzer`, not a cross-module
  architectural decision.
- All three histograms in the app become derivations handled outside
  the pipeline — consistent pattern, easier to reason about.
- `BufferAnalyzer.histogram` is trivially unit-testable (pure function
  of a buffer); the current code can only be tested through the
  pipeline actor.

## Interaction with todo 21

[Todo 21](21-derive-histograms-instead-of-recomputing.md) derives
`levelsHistogram` and `outputHistogram` from the source histogram via
bin remaps. If 21 has already landed (branch `refactor/histogram-derivation`
or its successor), this todo becomes a pure "move the one remaining
pixel-walk call out of the pipeline" — cleaner and smaller.

If 21 has *not* landed, do 21 first. It removes two other `HistogramData.compute`
call sites and makes it obvious that the pipeline's call is the
outlier.

Either ordering works; 21-then-22 reads better.

## Traps

1. **`RenderResult` is non-optional `histogram`** today, so a failed
   histogram compute sinks the whole render. After extraction, the
   buffer can succeed while the histogram computes later (or returns
   nil). Callers that previously relied on "if I have a result, I have
   a histogram" will need to treat them independently. In practice
   only `LevelsView` reads the source histogram directly; everything
   else goes through `viewModel.histogram` which stays optional.
2. **The pipeline fast-path currently reads both caches together.**
   Make sure the post-extraction fast path only checks the buffer
   cache and always runs the analyzer after. Don't accidentally
   introduce a second buffer cache check at the analyzer layer — one
   authoritative buffer cache, one analyzer call per render.
3. **Preserve the generation check ordering** — the supersession guard
   must run after the analyzer await, not before, otherwise an
   analyzer that completes during a newer render can still write
   stale data.
4. **`RenderPipeline.render` signature changes** from
   `… async -> RenderResult?` to `… async -> CIImage?`. Every caller in
   `ImageViewModel` needs the updated shape. Either rename to
   `renderBuffer` for clarity, or keep the name and just return a
   narrower type.
5. **Don't add a cache inside `BufferAnalyzer` preemptively.** Ship
   stateless first; measure; add caching only if profiling justifies it.

## Acceptance

- `curvelab/Utilities/BufferAnalyzer.swift` exists, 20–40 lines, no
  dependency on `RenderPipeline` or `RenderCache`.
- `RenderPipeline.swift` and `RenderCache.swift` contain zero
  occurrences of `HistogramData` / `Histogram` / `histogram`.
- `RenderResult` has exactly two fields.
- Levels panel, curve-editor backdrop, "After levels" panel, and
  "Output" panel all render correctly across: file load, rotate,
  invert, crop, levels drag, curve drag, preset apply, undo.
- Supersession still works: fast rotate-rotate-rotate does not leave
  the UI stuck on a stale histogram.
- Build stays warning-free.

## When to do this

Soon, but not emergency. Do it before adding any second buffer
derivation (clipping maps, focus peaks, auto-exposure, etc.) —
extracting one thing is easier than migrating two. Good fit as a
follow-up PR to the histogram-derivation branch; same conceptual
area, same week of work.

## Files

- **New:** `curvelab/Utilities/BufferAnalyzer.swift`
- **Modified:** `curvelab/Models/RenderResult.swift`,
  `curvelab/Utilities/RenderPipeline.swift`,
  `curvelab/Utilities/RenderCache.swift`,
  `curvelab/ViewModels/ImageViewModel.swift`
- **Unchanged:** all view files, `HistogramData.swift`,
  `RenderEngine.swift`, `RenderConfig.swift`.
