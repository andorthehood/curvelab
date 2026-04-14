# Reuse shared CIContext in HistogramData.compute

`HistogramData.swift:11` creates a new `CIContext` on every call to `compute(from:)`.
`CIContext` is expensive to initialize and is explicitly designed to be created once and reused.

## Fix

Pass the ViewModel's existing `CIContext` into `HistogramData.compute(from:context:)` as a
parameter instead of creating a new one internally.
