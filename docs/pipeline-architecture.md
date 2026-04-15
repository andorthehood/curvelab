# Render Pipeline Architecture

Companion to [`pipeline.md`](pipeline.md). That doc describes *what* the pixel
pipeline does; this one describes *who owns it* and *how* it's kept consistent
under concurrent UI-driven edits.

## The problem this architecture solves

Every cache-rebuilding action (rotate, invert, crop, load) used to be its own
`Task.detached` block inside `ImageViewModel`, with its own `MainActor.run`
writeback at the end:

```
self.cachedImage = …
self.histogram   = …
self.cropState   = …
self.isLoading   = false
```

Six such blocks existed. They shared no ordering guarantee, so a slow older
render could finish *after* a fast newer render and overwrite its results —
the preview and the controls would drift out of sync. Adding a new piece of
per-render state meant editing six sites in lockstep.

## Target: one owner, one result

The pipeline is now a single actor with a single entry point, producing a
single value-type result that the view model publishes as a whole.

```
┌─────────────────────────────────────────────────────────────┐
│                       ImageViewModel                         │
│                       (@MainActor)                           │
│                                                              │
│  UI state:                  @Published var result: Render-   │
│    rotationAngle            Result?  ◄─── single assignment  │
│    isNegative                                                │
│    appliedCropRect          cachedImage / histogram /        │
│    cropState                imageSize  ◄─── derived getters  │
│    inputBlackPoint                                           │
│    inputWhitePoint                                           │
│    curves                                                    │
│                                                              │
│  currentRenderConfig() ────► RenderConfig ──┐                │
└─────────────────────────────────────────────┼────────────────┘
                                              │
                                              ▼
┌─────────────────────────────────────────────────────────────┐
│                       RenderPipeline                         │
│                       (actor)                                │
│                                                              │
│  generation: Int   ◄── bumped on every render() call         │
│                                                              │
│  render(config, from:) ──► off-actor Task.detached          │
│                               ├── RenderEngine.buildBase     │
│                               ├── RenderEngine.crop          │
│                               └── RenderEngine.renderToBuffer│
│                            │                                 │
│                            ▼                                 │
│                       HistogramData.compute                  │
│                            │                                 │
│                            ▼                                 │
│                     guard gen == generation                  │
│                            │                                 │
│                            ▼                                 │
│                     RenderCache (LRU×3)                      │
│                            │                                 │
│                            ▼                                 │
│                      RenderResult?                           │
└─────────────────────────────────────────────────────────────┘
```

## The types

### `RenderConfig` — immutable snapshot of "what to render"

```swift
struct RenderConfig: Equatable, Hashable {
    let url: URL
    let rotation: Double
    let isNegative: Bool
    let cropRect: CGRect?
    var cacheKey: String { … }
}
```

One value-type snapshot of every input the pipeline consumes. Hashable so it
can key the LRU caches without string manipulation at the call site. The view
model builds one via `currentRenderConfig()` at each edit boundary and hands
it to the pipeline; the pipeline never reaches back into the view model for
state.

### `RenderResult` — immutable snapshot of "what came out"

```swift
struct RenderResult {
    let cachedImage: CIImage
    let histogram: HistogramData
    let extent: CGRect
}
```

One struct carrying everything the UI reads after a render: the float32
buffer, its histogram, and its dimensions. The view model stores it as
`@Published private(set) var result: RenderResult?` and exposes narrow
derived getters so existing call sites don't have to chase `.cachedImage`
every time.

### `RenderEngine` — stateless Core Image operations

Pure `enum` of `static func`s: `buildBase`, `rotate`, `crop`, `renderToBuffer`.
No `@MainActor`, no SwiftUI, no state. Safe to call from any task.

### `RenderCache` — the three LRUs

Three `LRUCache`s keyed differently:

| cache       | key              | capacity | holds                      |
|-------------|------------------|----------|----------------------------|
| `buffer`    | `RenderConfig`   | 3        | rendered float32 CIImage   |
| `histogram` | `RenderConfig`   | 3        | computed histogram         |
| `original`  | file URL         | 6        | lazy CIRAWFilter CIImage   |

Config-keyed so rotate / invert / crop variants of the same file coexist.
URL-keyed original so one file doesn't re-decode across those variants.

### `RenderPipeline` — the actor

```swift
actor RenderPipeline {
    private let cache = RenderCache()
    private let context: CIContext
    private var generation: Int = 0

    func original(for url: URL) -> CIImage?
    func setOriginal(_ image: CIImage, for url: URL)
    func render(_ config: RenderConfig, from original: CIImage) async -> RenderResult?
}
```

All serialisation goes through actor isolation. The heavy work is offloaded
to `Task.detached(priority: .userInitiated)` so other calls can enter and
bump the counter while it's running.

## How staleness is prevented

The classic ordering bug — older render finishes last and clobbers newer
state — is prevented by the generation counter:

```swift
func render(_ config: RenderConfig, from original: CIImage) async -> RenderResult? {
    generation += 1
    let gen = generation                 // ← captured at entry

    // … fast-path cache check …

    // Slow path: off-actor work
    let rendered = await Task.detached { … }.value
    let histData = await Task.detached { … }.value

    // Re-enter actor. A concurrent caller may have bumped generation
    // while we were off-actor.
    guard gen == generation else { return nil }
    // … cache and return RenderResult …
}
```

When a caller sees `nil`, it does *not* mutate UI state. The superseding
render (if any) owns the next update. Every call site reads:

```swift
guard let result = await pipeline.render(config, from: original) else { return }
self.result = result
```

— one assignment, not six. Any state derived from the result (`cachedImage`,
`histogram`, `imageSize`, crop extent) updates in one atomic publisher tick.

## Cache-hit latency

A repeat configuration (e.g. rotating back to an orientation you just left)
hits the LRU and skips `Task.detached` entirely. The fast path:

```swift
if let cached = cache.buffer(for: config),
   let hist   = cache.histogram(for: config) {
    return RenderResult(cachedImage: cached, histogram: hist, extent: cached.extent)
}
```

The caller still awaits the actor — sub-millisecond on a hit — so the flow
is uniformly async.

## What the view model still does

`ImageViewModel` owns *editing decisions*: rotation angle, negative toggle,
crop rect, levels, curves, undo stack, sidecar load/save, file metadata,
live thumbnails, preset thumbnails. It does **not** own the pixel buffer,
the histogram, the dimensions, or the LRU caches — those are derived from
`result`.

`updatePreview()` (the real-time LUT application) still lives on the view
model because it runs on every curve frame and doesn't go through the
expensive render path — it applies a GPU LUT filter directly to
`result.cachedImage`.

## What this fixes

- **#12** — stale rebuild clobbering newer: gone (generation counter).
- **#09** — `imageSize` not reactive: gone (derived from `@Published result`).
- **#10** — histogram stale after rotate: gone (histogram is inside `result`).
- **#18** — `loadFile` restoration duplicated: gone (one async flow, one commit).
- **#19** — `rebuildCache` MainActor block duplicated: gone (one assignment per action).
- **#07** — rotation reapplied on every preview rebuild: gone (rotation is
  baked into `result.cachedImage`; `updatePreview` just applies LUTs).

## What it doesn't fix

**#17** (ImageViewModel god object) remains open. The pixel-pipeline half has
moved out, but the UI-coordinator half (thumbnails, undo, sidecar, presets)
still lives on `ImageViewModel`. Splitting it further is tracked as a
separate, lower-priority cleanup.
