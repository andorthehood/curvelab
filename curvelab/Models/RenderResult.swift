import CoreImage
import Foundation

/// The output of rendering a `RenderConfig`: the float32 pixel buffer wrapped as
/// a `CIImage`, plus its histogram. `extent` is stored separately so downstream
/// consumers can read image dimensions without touching the CIImage.
///
/// Currently unused; will become the single value written back from the render
/// pipeline in a later step, replacing the scattered `cachedImage` / `histogram`
/// / `cropState` writes on `ImageViewModel`.
struct RenderResult {
    let cachedImage: CIImage
    let histogram: HistogramData
    let extent: CGRect
}
