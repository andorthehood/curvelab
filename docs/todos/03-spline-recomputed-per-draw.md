# Avoid redundant CubicSpline construction per frame

`CurveEditorView` calls `curve.spline()` separately in `drawInactiveCurves`, `drawActiveCurve`,
and `drawHandles` on every render — up to 7 spline constructions per frame during a drag.
Each construction runs the Thomas algorithm tridiagonal solve, which is wasted repeated work.

## Fix

Compute all four splines once at the top of the `Canvas` closure and pass them into the draw
functions as parameters.
