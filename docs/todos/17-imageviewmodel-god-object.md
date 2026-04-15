# 17 — ImageViewModel still mixes editing, coordination, undo, and I/O

## Status

**Partially done.** The pixel-rendering half was extracted in the render-pipeline
refactor (see [`docs/pipeline-architecture.md`](../pipeline-architecture.md)):
`RenderEngine`, `RenderCache`, and the `RenderPipeline` actor now own all CPU-heavy
Core Image work. This todo used to propose extracting those too — that work is
done, do **not** re-do it.

What remains is a UI-coordination god object: `ImageViewModel` still owns file
loading, sidecar persistence, an undo stack, preset thumbnail rendering, a live
thumbnail for the recent-files bar, JPEG export, curve-editing math, and the
Combine wiring that glues them together.

## Current state

**File:** `curvelab/ViewModels/ImageViewModel.swift` — ~627 lines, `@MainActor`,
`ObservableObject`. Deleting the pipeline half didn't shrink it much; there's
still a lot of surface here.

### What's on it today

Broken down by concern (line ranges approximate, current as of commit on branch
`refactor/render-pipeline`):

| Concern | Published props | Methods | Rough lines |
|---|---|---|---|
| Pixel-pipeline driver | `result`, `originalImage`, `previewImage`, `cacheVersion`, `levelsHistogram`, `outputHistogram` | `rotateLeft/Right`, `preparedBase`, `rebuildCache`, `applyCrop`, `resetCrop`, `updatePreview` | 222–352 |
| Editing decisions (state only) | `curves`, `rotationAngle`, `cropState`, `isNegative`, `inputBlackPoint`, `inputWhitePoint`, `cropAspectRatio`, `showCropOverlay`, `exportLinear` | — | declared 10–22 |
| Curves math | — | `setBlackPointWithCurves`, `absorbCurveBlackPoint`, `linkedBlackPointMax`, `stretchCurves`, `resetCurves` | 354–420 |
| File loading / metadata | `sourceURL`, `fileName` | `importImage`, `openURL`, `loadFile` | 122–206 |
| Presets | `presetThumbnails` | `capturePreset`, `applyPreset`, `renderThumbnails` | 422–487 |
| Export | — | `exportJPG` | 489–528 |
| Undo | `canUndo` | `recordUndoPoint`, `undo`, `applyEditingState`, `undoStack`, `lastSavedData`, `maxUndoSteps` | 530–594 |
| Sidecar I/O | — | `currentEditingState`, `saveState` | 596–625 |
| Live thumbnails | `activeFileLiveThumbnail` | `renderSmallThumbnail`, thumbnail code inside `updatePreview` | 209–220, 240–256 |
| Glue | `willLoadNewFile` callback, Combine sinks in `init` | — | 84–120 |

### External consumers (what reads the view model)

A fresh agent should not move a `@Published` property without tracing its
bindings. Quick reference:

- `ContentView.swift` reads almost everything; holds `$viewModel.isNegative`,
  `$viewModel.inputBlackPoint`, `$viewModel.inputWhitePoint`,
  `$viewModel.cropState`, `$viewModel.showCropOverlay`, `$viewModel.exportLinear`,
  `$viewModel.curves.activeChannel`. Also wires `viewModel.willLoadNewFile` in
  `.onAppear` and watches `viewModel.sourceURL` with `.onChange`.
- `PresetsView.swift` reads `hasCachedImage`, `presetThumbnails`, `imageSize`,
  and watches `cacheVersion` with `.onChange` to re-render preset thumbs.
- `RecentFilesView.swift` reads `sourceURL`, `activeFileLiveThumbnail`,
  and calls `viewModel.openURL(_:)`.

`cacheVersion` is a `UUID` bumped on every successful cache rebuild — used
purely as a trigger for `.onChange(of: cacheVersion)`. Any split must keep
this trigger fireable by whatever now owns rebuild completion.

## Proposed split

Extract in order. Each step is independently shippable, leaves the app working,
and makes later steps easier. Stop whenever the remaining complexity feels
acceptable.

### Step A — `UndoHistory<T: Codable>`

Pull the stack (`undoStack`, `lastSavedData`, `maxUndoSteps`, `canUndo`,
`recordUndoPoint`, `undo`) into a generic `UndoHistory<EditingState>` class.
Owns the `@Published canUndo` and exposes `record(_:)`, `pop() -> T?`, and a
`clear()`. The view model holds one as a property; `recordUndoPoint()` becomes
`history.record(currentEditingState())`. Smallest, cleanest extraction — no
bindings move, no views change except `$viewModel.canUndo` → `viewModel.history.canUndo`
(or a forwarded getter).

### Step B — `SidecarStore`

Move `currentEditingState`, `saveState`, and the sidecar-read half of
`loadFile` into a `SidecarStore` (non-isolated). Depends only on `URL` and
`EditingState`. Tiny surface: `load(for: URL) -> EditingState?` and
`save(_:for: URL)`. Pure I/O; trivially testable.

### Step C — `PresetCoordinator`

Move `capturePreset`, `applyPreset`, `renderThumbnails`, `presetThumbnails`
to a `PresetCoordinator` (`@MainActor`, `ObservableObject`). It needs read
access to the current `RenderResult.cachedImage` for thumbnails and
write access to curves/levels/negative for apply. Pass those via an
adapter protocol or a closure — don't back-reference the view model.
`PresetsView` switches from `@ObservedObject var viewModel` to also holding
`@ObservedObject var presets`.

### Step D — `FileCoordinator`

Owns `sourceURL`, `fileName`, `willLoadNewFile`, `importImage`, `openURL`,
and drives `loadFile`. The pipeline call stays here because it fans out
to reset editing state on the view model. This one is larger — be careful
with the Combine `$isNegative` sink, which must fire on *editing changes*
not on file-load. `suppressCacheRebuild` exists specifically to prevent
sidecar restoration from triggering a double rebuild; preserve that.

### Step E — `ExportService`

`exportJPG` takes `previewImage`, `fileName`, `exportLinear`, and produces
a file. Moves cleanly as a non-isolated service; view model passes it the
snapshot state.

### What stays on `ImageViewModel`

After A–E, the view model should be essentially: editing decisions
(rotation/crop/levels/curves/negative), the `RenderPipeline`, `updatePreview`,
and the `@Published result`. Close to the "thin coordination layer" the
original todo described, but applied to the UI half rather than the pixel
half.

## Traps / context the pipeline refactor baked in

Read these before touching anything:

1. **`result` is the single source of truth** for anything derived from the
   pixel buffer: `cachedImage`, `histogram`, `imageSize`, `hasCachedImage`.
   Don't re-introduce parallel `@Published` fields for them.
2. **The `$isNegative` Combine sink** in `init()` fires in `willSet`, so
   `self.isNegative` still reads the old value when the sink runs —
   `rebuildCache(invert:)` is called with the new value as a parameter.
   `recordUndoPoint()` captures the *pre-toggle* state by design.
3. **`suppressCacheRebuild`** is a one-frame flag: set to `true` before
   mutating state during sidecar restoration or undo, cleared after. Without
   it, setting `isNegative` from restored state fires the sink and triggers
   a redundant rebuild.
4. **`cacheVersion`** is the external "something changed, re-render
   thumbnails" signal. `PresetsView` listens via `.onChange`. If you split
   preset rendering out, it needs a different trigger (e.g. observing
   `result`).
5. **`willLoadNewFile` callback** is wired by `ContentView.onAppear` to
   save the outgoing live thumbnail to the recent-files store *before*
   `sourceURL` changes. Don't drop this ordering when moving file-loading.
6. **Xcode project** uses `PBXFileSystemSynchronizedRootGroup` — new files
   dropped into the source folders are picked up without `.pbxproj` edits.
   Put new files in `curvelab/Models/`, `curvelab/Utilities/`, or a new
   `curvelab/Coordinators/` folder as appropriate.
7. **Undo snapshots are JSON `Data`**, not structs, so the stack handles
   deduplication via byte equality without needing `EditingState: Equatable`.
   Preserve this if rewriting `UndoHistory`.

## Acceptance

- `ImageViewModel.swift` drops below ~300 lines.
- No single extracted type depends on `ImageViewModel` (one-way arrows).
- All existing external bindings keep working — `ContentView`, `PresetsView`,
  `RecentFilesView` compile without logic changes (imports / property paths
  are fine).
- Build stays warning-free.
- Undo, sidecar save/load, preset thumbnails, recent-files thumbnails,
  rotate, crop, invert, export all still work end-to-end.

## When to do this

Not urgent. The pipeline refactor resolved the critical races; the remaining
concerns cohabit fine for now. Do it before adding a second major editing
tool (HSL, sharpening, white balance) or before adding batch/queue export —
both will push past the comfortable limit.
