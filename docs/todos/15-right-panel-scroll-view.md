# 15 — Right panel needs a ScrollView

## Problem

The right-hand editing panel is a plain `VStack` with a fixed half-width
frame.  As more controls are added (levels strip, after-levels histogram,
curve editor, output histogram, toggles, crop buttons) the panel overflows
on smaller displays or when the window is resized short.

## Fix

Wrap the panel `VStack` in a `ScrollView(.vertical, showsIndicators: true)`
so controls remain accessible at any window height.  The curve editor's
`aspectRatio(1, contentMode: .fit)` constraint already limits its height
to the available width, so it will scale naturally inside the scroll view.
