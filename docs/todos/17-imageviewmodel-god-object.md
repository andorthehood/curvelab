# 17 — ImageViewModel is a growing god object

## Problem

`ImageViewModel` currently owns: image loading, cache rebuilding, rotation, crop, levels,
preview rendering, histogram computation, preset capture/apply/thumbnails, export, and
sidecar persistence. Every new tool adds more state and methods here. It will become
hard to test, reason about, and extend.

## Proposed split

**`PipelineEngine`** — a non-isolated (or actor-isolated) type owning the stateless
heavy lifting. All the existing `nonisolated static` helpers are natural candidates:

- `buildBase(from:rotation:invert:)`
- `applyCrop(_:to:)`
- `renderToBuffer(_:context:)`
- `LUTGenerator.applyFilter` calls
- Histogram computation

These have no dependency on SwiftUI or `@MainActor` and are already `nonisolated static`.
Extracting them makes them independently testable and reusable (e.g. by a future batch
export pipeline).

**`ImageViewModel`** becomes a thin coordination layer: holds `@Published` state, owns
the `CIContext`, dispatches work to `PipelineEngine` via `Task.detached`, and writes
results back on `MainActor`.

## When to do this

Before adding a second major editing tool (e.g. HSL, sharpening) or before adding
batch/queue processing. Doing it earlier keeps the refactor small.
