# 14 — Levels LUT rebuilt unnecessarily on curve drag

## Problem

`updatePreview()` builds two full 33³ LUTs on every call: one for the
final preview (levels + curves) and one for the post-levels histogram
(levels + identity curves).  The second LUT only needs to change when
`inputBlackPoint` or `inputWhitePoint` change, but currently it is
rebuilt on every curve point drag as well.

## Fix

Split the two concerns:

- `updateLevelsHistogram()` — called only from the `$inputBlackPoint` /
  `$inputWhitePoint` Combine sink.  Applies the levels-only LUT and
  recomputes `levelsHistogram`.

- `updatePreview()` — called from the curves sink and from anywhere the
  preview needs a full refresh.  Applies the full levels + curves LUT and
  recomputes `outputHistogram`.  Does **not** touch `levelsHistogram`.

On every curve drag only one LUT is built instead of two.
