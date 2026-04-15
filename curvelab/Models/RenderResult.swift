import CoreImage
import Foundation

/// The output of rendering a `RenderConfig`: the float32 pixel buffer wrapped as
/// a `CIImage`, plus its histogram. `extent` is stored separately so downstream
/// consumers can read image dimensions without touching the CIImage.
///
/// Held by `ImageViewModel.result` as the single source of truth for rendered
/// output. Views read derived accessors (`cachedImage`, `histogram`, `imageSize`)
/// rather than the struct directly.
struct RenderResult {
    let cachedImage: CIImage
    let histogram: HistogramData
    let extent: CGRect
}
