# 20 — Render pipeline refactor (decouple pixel work from UI)

## Motivation

Several open todos are symptoms of the same architectural issue: there is no
single owner of *"what configuration is the pixel pipeline currently rendering?"*
`ImageViewModel` holds both UI state and pipeline state, and six parallel
`Task.detached` sites mutate overlapping subsets of it. Related todos that
collapse into this one:

- **#12** — six unsynchronized writeback sites cause stale results to clobber fresh ones
- **#17** — ImageViewModel god object
- **#18** — `loadFile` state restoration duplicated
- **#19** — `rebuildCache` MainActor block duplicated
- **#07** — rotation reapplied on every preview rebuild
- **#09** — `imageSize` not reactive
- **#10** — histogram stale after rotate

## Target architecture

Split pixel work from UI state via two plain value types and one actor:

- **`RenderConfig`** *(struct, Equatable)* — `url`, `rotation`, `isNegative`, `cropRect`
- **`RenderResult`** *(struct)* — `cachedImage`, `histogram`, `extent`
- **`RenderPipeline`** *(actor)* — owns LRU caches, render engine, and a monotonic
  generation counter; exposes one entry:
  ```swift
  func render(_ config: RenderConfig, from original: CIImage) async -> RenderResult?
  ```
  Stale completions are dropped internally via the generation counter.

`ImageViewModel` shrinks to: hold a `RenderConfig`, hold a `@Published RenderResult?`,
forward config changes to the pipeline. The six existing `MainActor.run { self.cachedImage = …; self.histogram = …; … }` blocks collapse into a single assignment.

## Independently deployable steps

Each step ships on its own, leaves the app working, and makes the next step smaller.

### Step 1 — Extract pure value types
Add `RenderConfig` and `RenderResult` structs. Add a `currentRenderConfig()` helper on
`ImageViewModel`. Use it immediately to dedupe the three copies of cache-key
construction. **No behavior change.**

### Step 2 — Extract render functions into `RenderEngine`
Move `buildBase`, `rotatedImage`, `applyCrop`, `renderToBuffer`, and histogram
orchestration out of the view model into a non-isolated `enum RenderEngine`
(or similar). **No behavior change.**

### Step 3 — Extract LRU caches into `RenderCache`
`bufferCache`, `originalCache`, `histogramCache`, and `bufferCacheKey()` move
into one type. **No behavior change.** After this, engine + cache live together
and are ready to be wrapped by the actor.

### Step 4 — Introduce `RenderPipeline` actor, migrate only `rebuildCache`
Actor wraps engine + cache, exposes the single `render(config:from:)` entry,
owns the generation counter. `rotateLeft`/`rotateRight`/the `$isNegative` sink
route through it. `applyCrop`, `resetCrop`, `loadFile` still use the old path
for now. **Observable fix: rotate↔rotate and rotate↔invert races gone.**

### Step 5 — Migrate `applyCrop` and `resetCrop`
Both now go through the same pipeline entry. Slow/fast path duplication
collapses into one call. **Fixes crop↔rotate and crop↔invert races.**
This step deletes the most code.

### Step 6 — Migrate `loadFile`
Biggest step because of sidecar restoration. Becomes:
decode DNG → build `RenderConfig` from sidecar → `pipeline.render(config, from: decoded)`.
The pipeline's generation bump also invalidates any in-flight rebuild from the
previous file. **Fully closes #12.** Also resolves #18.

### Step 7 — Collapse view-model state to `@Published var result: RenderResult?`
`cachedImage`, `histogram`, `cropState`, `appliedCropRect`, `imageSize` all
become derived from `result`. The six `MainActor.run` writebacks collapse to
one assignment. **Fixes #09 and #10 as free side effects.**

### Step 8 (optional) — Split UI state off ImageViewModel
`fileName`, `isLoading`, `showCropOverlay`, `cropAspectRatio`, `presetThumbnails`,
`activeFileLiveThumbnail`, undo stack → separate coordinator. Addresses #17.
Not required to fix #12.

## Suggested stopping points

- After **Step 4**: worst race (rotate↔rotate) fixed, code still mostly recognizable.
- After **Step 6**: #12 fully closed. Safe park.
- After **Step 7**: architectural win banked; #17 cleanup can wait indefinitely.

## Follow-up

Once the refactor lands, replace this todo with a `docs/pipeline-architecture.md`
describing the final system (alongside the existing `docs/pipeline.md`).
