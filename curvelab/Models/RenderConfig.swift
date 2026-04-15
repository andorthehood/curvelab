import CoreImage
import Foundation

/// Identifies a unique rendered output of the pixel pipeline.
///
/// Two `RenderConfig`s with equal fields describe the same cached buffer —
/// this is what the render cache is keyed on. Levels and curves are NOT part
/// of the config: they only affect the LUT applied at preview time, not the
/// cached float32 buffer.
struct RenderConfig: Equatable, Hashable {
    let url: URL
    let rotation: Double
    let isNegative: Bool
    let cropRect: CGRect?

    /// Stable string key for the LRU cache.
    var cacheKey: String {
        let crop = cropRect.map {
            "\($0.origin.x),\($0.origin.y),\($0.width),\($0.height)"
        } ?? "none"
        return "\(url.path)|\(rotation)|\(isNegative)|\(crop)"
    }
}
