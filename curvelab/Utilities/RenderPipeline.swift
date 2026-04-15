import CoreImage
import Foundation

/// Serializes the pixel-rendering pipeline and protects against stale
/// completions clobbering fresh ones.
///
/// Every call to `render(_:from:)` bumps an internal generation counter and
/// captures its value. After the heavy work (off-actor in a detached task)
/// finishes, the captured value is compared against the current generation:
/// if a newer render has started in the meantime, this one returns `nil` and
/// its result is discarded.
///
/// During the incremental migration described in `docs/todos/20`, this actor
/// owns its own `RenderCache`, disjoint from the cache still on
/// `ImageViewModel`. That means rotate↔crop etc. don't yet share cache hits,
/// but each isolation boundary is internally consistent. The caches merge
/// when `loadFile` migrates in Step 6.
actor RenderPipeline {
    private let cache = RenderCache()
    private let context: CIContext
    private var generation: Int = 0

    init(context: CIContext) {
        self.context = context
    }

    /// Renders `config` from the supplied decoded original.
    ///
    /// Returns `nil` when a newer render has superseded this call, or when
    /// rendering itself fails. Callers should treat `nil` as "do not mutate
    /// UI state" — the superseding render (if any) will produce the next
    /// visible result.
    func render(_ config: RenderConfig, from original: CIImage) async -> RenderResult? {
        generation += 1
        let gen = generation

        // Fast path: this exact configuration is already cached.
        if let cached = cache.buffer(for: config),
           let hist   = cache.histogram(for: config) {
            return RenderResult(cachedImage: cached, histogram: hist, extent: cached.extent)
        }

        // Slow path: do the CPU-heavy render off-actor so other calls can
        // enter and bump the generation while we work.
        let context = context
        let rendered: CIImage? = await Task.detached(priority: .userInitiated) {
            let base    = RenderEngine.buildBase(from: original,
                                                 rotation: config.rotation,
                                                 invert: config.isNegative)
            let toCache = RenderEngine.crop(config.cropRect, to: base)
            return RenderEngine.renderToBuffer(toCache, context: context)
        }.value

        let histData: HistogramData?
        if let rendered {
            histData = await Task.detached(priority: .userInitiated) {
                HistogramData.compute(from: rendered, context: context)
            }.value
        } else {
            histData = nil
        }

        // Supersession check: a newer render bumped the counter while we
        // were working, so this result is stale.
        guard gen == generation else { return nil }
        guard let rendered, let histData else { return nil }

        cache.setBuffer(rendered, for: config)
        cache.setHistogram(histData, for: config)
        return RenderResult(cachedImage: rendered, histogram: histData, extent: rendered.extent)
    }
}
