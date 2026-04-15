import CoreImage
import Foundation

/// Owns all LRU caches feeding the render pipeline.
///
/// Two axes of caching:
/// - **Buffer + histogram** are keyed on the full `RenderConfig` so different
///   rotation / inversion / crop combinations of the same file coexist.
/// - **Original** (the lazy `CIRAWFilter` CIImage from DNGLoader) is keyed on
///   just the file URL — rotation/crop are applied on top, so one per file.
///
/// Capacities match the historical tuning (one buffer entry can be 300–600 MB
/// at full resolution; originals are lazy and cheap).
///
/// Not thread-safe on its own — serialised by the `RenderPipeline` actor
/// that owns it. All access goes through the actor.
final class RenderCache {
    private let buffer    = LRUCache<String, CIImage>(capacity: 3)
    private let histogram = LRUCache<String, HistogramData>(capacity: 3)
    private let original  = LRUCache<String, CIImage>(capacity: 6)

    // MARK: - Config-keyed (rendered buffer + histogram)

    func buffer(for config: RenderConfig) -> CIImage? {
        buffer.get(config.cacheKey)
    }

    func setBuffer(_ image: CIImage, for config: RenderConfig) {
        buffer.set(config.cacheKey, image)
    }

    func histogram(for config: RenderConfig) -> HistogramData? {
        histogram.get(config.cacheKey)
    }

    func setHistogram(_ data: HistogramData, for config: RenderConfig) {
        histogram.set(config.cacheKey, data)
    }

    // MARK: - URL-keyed (lazy original CIImage)

    func original(for url: URL) -> CIImage? {
        original.get(url.path)
    }

    func setOriginal(_ image: CIImage, for url: URL) {
        original.set(url.path, image)
    }
}
