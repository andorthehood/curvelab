import SwiftUI
import CoreImage
import Combine
import UniformTypeIdentifiers

@MainActor
class ImageViewModel: ObservableObject {
    @Published var originalImage: CIImage?
    @Published var previewImage: CIImage?
    @Published var curves = CurveModel()
    @Published var isLoading = false
    @Published var fileName = "CurveLab"
    @Published var levelsHistogram: HistogramData?
    @Published var outputHistogram: HistogramData?
    @Published var rotationAngle: Double = 0
    @Published var cropState: CropState = CropState(rect: .zero, isActive: false)
    @Published var showCropOverlay = false
    @Published var cropAspectRatio: CGSize? = nil
    @Published var isNegative = false
    @Published var exportLinear = false
    @Published var inputBlackPoint: Double = 0.0
    @Published var inputWhitePoint: Double = 1.0
    @Published var presetThumbnails: [UUID: CGImage] = [:]
    @Published private(set) var cacheVersion: UUID = UUID()
    @Published private(set) var sourceURL: URL? = nil
    @Published private(set) var activeFileLiveThumbnail: CGImage? = nil

    /// Latest successfully rendered output: the float32 buffer CIImage, its
    /// histogram, and extent. Single source of truth — replaces the separate
    /// `cachedImage` + `histogram` fields we used to carry.
    @Published private(set) var result: RenderResult?

    /// Called after the user selects a new file (panel or recent-files click) but
    /// before `sourceURL` changes — ContentView uses this to save the outgoing thumbnail.
    var willLoadNewFile: (() -> Void)? = nil

    // MARK: - Derived accessors (from `result`)

    /// Post-cache-rebuild histogram. Observed by views for levels / curve plots.
    var histogram: HistogramData? { result?.histogram }

    /// Pixel dimensions of the most recent render, or `.zero` before any load.
    var imageSize: CGSize {
        guard let ext = result?.extent else { return .zero }
        return CGSize(width: ext.width, height: ext.height)
    }

    var hasCachedImage: Bool { result != nil }
    var exportCropRect: CGRect? { appliedCropRect }

    /// The float32 buffer CIImage fed into LUT application and thumbnails.
    /// Private because only this file's updatePreview / renderThumbnails read it.
    private var cachedImage: CIImage? { result?.cachedImage }

    private var appliedCropRect: CGRect? = nil

    // Suppresses the $isNegative → rebuildCache sink during import
    // so we don't rebuild twice when loading a sidecar.
    private var suppressCacheRebuild = false

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Serialized render pipeline. Owns the rendering CIContext, the LRU
    /// caches (buffer / histogram / original), and a generation counter that
    /// discards stale completions. All pixel work goes through here.
    private lazy var pipeline = RenderPipeline(context: ciContext)

    /// Snapshot of the current pixel-pipeline configuration, or `nil` when no
    /// file is loaded. `invertOverride` lets callers build a config reflecting
    /// a value that hasn't yet been committed to `self.isNegative` — used by
    /// the `$isNegative` sink, which fires in `willSet` before the property
    /// has the new value.
    private func currentRenderConfig(invertOverride: Bool? = nil) -> RenderConfig? {
        guard let sourceURL else { return nil }
        return RenderConfig(
            url: sourceURL,
            rotation: rotationAngle,
            isNegative: invertOverride ?? isNegative,
            cropRect: appliedCropRect
        )
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        curves.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updatePreview() }
            .store(in: &cancellables)

        // Auto-save after curve edits settle
        curves.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveState() }
            .store(in: &cancellables)

        $isNegative
            .dropFirst()
            .sink { [weak self] invert in
                guard let self, !self.suppressCacheRebuild else { return }
                // @Published fires in willSet — self.isNegative is still the OLD value here,
                // so recordUndoPoint captures the correct pre-toggle state.
                self.recordUndoPoint()
                self.rebuildCache(invert: invert)
            }
            .store(in: &cancellables)

        // Levels changes are real-time — just rebuild the LUT preview
        Publishers.CombineLatest($inputBlackPoint, $inputWhitePoint)
            .dropFirst()
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updatePreview() }
            .store(in: &cancellables)

        // Auto-save after levels settle
        Publishers.CombineLatest($inputBlackPoint, $inputWhitePoint)
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveState() }
            .store(in: &cancellables)
    }

    // MARK: - Import

    func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rawImage, .tiff, .png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        willLoadNewFile?()
        loadFile(url: url)
    }

    /// Opens a file directly by URL — used by the recent files bar to skip the panel.
    func openURL(_ url: URL) {
        willLoadNewFile?()
        loadFile(url: url)
    }

    private func loadFile(url: URL) {
        fileName = url.deletingPathExtension().lastPathComponent
        sourceURL = url

        // Load sidecar if one exists
        let state = (try? Data(contentsOf: url.curvelabSidecar))
            .flatMap { try? JSONDecoder().decode(EditingState.self, from: $0) }

        let rotation   = state?.rotation        ?? 0
        let invertNeg  = state?.isNegative      ?? false
        let cropRect   = state?.appliedCropRect?.cgRect
        let blackPoint = state?.inputBlackPoint ?? 0.0
        let whitePoint = state?.inputWhitePoint ?? 1.0

        suppressCacheRebuild = true
        isLoading = true

        let config = RenderConfig(url: url, rotation: rotation,
                                  isNegative: invertNeg, cropRect: cropRect)

        Task { [pipeline] in
            // 1. Resolve the decoded original — cached or via DNGLoader.
            let original: CIImage
            if let cached = await pipeline.original(for: url) {
                original = cached
            } else {
                guard let decoded = await Task.detached(priority: .userInitiated, operation: {
                    DNGLoader.load(url: url)
                }).value else {
                    self.isLoading = false
                    self.suppressCacheRebuild = false
                    return
                }
                await pipeline.setOriginal(decoded, for: url)
                original = decoded
            }

            // 2. Render (may hit cache for recently-viewed configurations).
            //    Returns nil if a newer loadFile or rebuildCache superseded us.
            guard let result = await pipeline.render(config, from: original) else {
                return
            }

            // 3. Commit all state on MainActor (Task inherits MainActor from self).
            self.originalImage   = original
            self.result          = result
            self.rotationAngle   = rotation
            self.isNegative      = invertNeg
            self.appliedCropRect = cropRect
            self.cropState       = cropRect != nil
                ? CropState(rect: result.extent, isActive: true)
                : CropState.full(for: result.cachedImage)
            self.showCropOverlay = false
            self.cropAspectRatio = nil
            self.inputBlackPoint = blackPoint
            self.inputWhitePoint = whitePoint
            if let state { state.apply(to: self.curves) } else { self.curves.reset() }
            self.suppressCacheRebuild = false
            self.undoStack.removeAll()
            self.lastSavedData = nil
            self.canUndo = false
            self.cacheVersion = UUID()
            self.updatePreview()
            self.isLoading = false
            self.saveState()
        }
    }

    /// Renders the current preview to a small CGImage (256px wide) for thumbnail storage.
    func renderSmallThumbnail(completion: @escaping (CGImage?) -> Void) {
        guard let preview = previewImage else { completion(nil); return }
        let context = ciContext
        let image   = preview
        Task.detached {
            let scale   = min(1.0, 256.0 / image.extent.width)
            let scaled  = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let cg      = context.createCGImage(scaled, from: scaled.extent, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            await MainActor.run { completion(cg) }
        }
    }

    // MARK: - Preview

    func updatePreview() {
        guard let cachedImage else {
            previewImage = nil
            levelsHistogram = nil
            outputHistogram = nil
            return
        }
        let preview = LUTGenerator.applyFilter(to: cachedImage, curves: curves,
                                               blackPoint: inputBlackPoint, whitePoint: inputWhitePoint)
        previewImage = preview

        // Derive the levels and output histograms from the cached source
        // histogram by remapping its 256 bins — no pixel walk, no Task.detached
        // round-trip, no stale-writeback race. `result.histogram` is already
        // computed post-rotate/invert/crop, so composing levels and curves on
        // top matches `LUTGenerator.applyFilter`'s order (levels → curves).
        let source = result?.histogram
        let lvl    = source?.remapped(throughLevels: inputBlackPoint,
                                      whitePoint:    inputWhitePoint)
        levelsHistogram = lvl
        outputHistogram = lvl?.remapped(through: curves)

        // Live thumbnail for the recent files bar (256 px wide). `createCGImage`
        // is genuinely expensive, so keep it off the main actor.
        let context = ciContext
        Task.detached {
            let thumbScale  = min(1.0, 256.0 / preview.extent.width)
            let thumbScaled = preview.transformed(by: CGAffineTransform(scaleX: thumbScale, y: thumbScale))
            let thumbCG     = context.createCGImage(thumbScaled, from: thumbScaled.extent,
                                                    format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            await MainActor.run {
                self.activeFileLiveThumbnail = thumbCG
            }
        }
    }

    // MARK: - Rotation

    func rotateLeft() {
        recordUndoPoint()
        rotationAngle = (rotationAngle - 90).truncatingRemainder(dividingBy: 360)
        if rotationAngle < 0 { rotationAngle += 360 }
        appliedCropRect = nil
        rebuildCache()
    }

    func rotateRight() {
        recordUndoPoint()
        rotationAngle = (rotationAngle + 90).truncatingRemainder(dividingBy: 360)
        appliedCropRect = nil
        rebuildCache()
    }

    // MARK: - Cache rebuild

    /// Returns originalImage with rotation + optional inversion applied (no crop).
    private func preparedBase(invert: Bool? = nil) -> CIImage? {
        guard let originalImage else { return nil }
        return RenderEngine.buildBase(from: originalImage, rotation: rotationAngle,
                              invert: invert ?? isNegative)
    }

    private func rebuildCache(invert: Bool? = nil) {
        guard let original = originalImage,
              let config   = currentRenderConfig(invertOverride: invert) else { return }
        isLoading = true
        let hasCrop = config.cropRect != nil

        Task { [pipeline] in
            guard let result = await pipeline.render(config, from: original) else {
                // Superseded by a newer render, or render failed. Don't
                // mutate UI state — the newer render (if any) will own the
                // next update. isLoading is intentionally left set; the final
                // completing render will clear it.
                return
            }
            self.result       = result
            self.cropState    = hasCrop
                ? CropState(rect: result.extent, isActive: true)
                : CropState.full(for: result.cachedImage)
            self.cacheVersion = UUID()
            self.updatePreview()
            self.isLoading    = false
            self.saveState()
        }
    }

    // MARK: - Crop

    func applyCrop() {
        recordUndoPoint()
        // Clamp the user-drawn rect against the rotated base extent before
        // committing. preparedBase() returns a lazy CIImage — this is pure
        // geometry, no pixel work.
        guard let original = originalImage,
              let base     = preparedBase() else { return }
        let clampedState = cropState.clamped(to: base.extent)
        appliedCropRect  = clampedState.rect
        isLoading = true

        guard let config = currentRenderConfig() else { return }
        Task { [pipeline] in
            guard let result = await pipeline.render(config, from: original) else { return }
            self.result       = result
            self.cropState    = CropState(rect: result.extent, isActive: true)
            self.cacheVersion = UUID()
            self.updatePreview()
            self.isLoading    = false
            self.saveState()
        }
    }

    func resetCrop() {
        recordUndoPoint()
        guard let original = originalImage else { return }
        appliedCropRect = nil
        isLoading = true

        guard let config = currentRenderConfig() else { return }
        Task { [pipeline] in
            guard let result = await pipeline.render(config, from: original) else { return }
            self.result       = result
            self.cropState    = CropState.full(for: result.cachedImage)
            self.cacheVersion = UUID()
            self.updatePreview()
            self.isLoading    = false
            self.saveState()
        }
    }

    // MARK: - Curves

    /// Moves the input levels black point to `newBP` while adjusting curves so that
    /// every pixel's output value is preserved. Equivalent to running absorbCurveBlackPoint
    /// in real time as the linked handle is dragged.
    func setBlackPointWithCurves(_ newBP: Double) {
        let delta = newBP - inputBlackPoint
        guard delta != 0 else { return }
        let range = inputWhitePoint - inputBlackPoint
        guard range > 1e-10 else { return }
        let x0 = delta / range   // normalised increment in post-levels space
        stretchCurves(by: x0)
        inputBlackPoint = newBP
    }

    /// Absorbs the active channel's black-point shift into the input levels black point,
    /// then stretches the appropriate curves back to fill [0, 1]. Output is mathematically unchanged.
    func absorbCurveBlackPoint() {
        recordUndoPoint()
        let x0 = curves.activeCurve.sortedPoints.first?.x ?? 0
        guard x0 > 0 else { return }

        let range = inputWhitePoint - inputBlackPoint
        inputBlackPoint += x0 * range
        stretchCurves(by: x0)
    }

    /// Maximum value the linked black-point handle may reach — the point at which the
    /// relevant curve's leftmost control point would land exactly at x = 0 after stretching.
    /// Dragging beyond this would clamp the leftmost point to 0 and destroy the curve shape.
    var linkedBlackPointMax: Double {
        let leftmostX: Double
        switch curves.activeChannel {
        case .rgb:
            leftmostX = curves.rgb.sortedPoints.first?.x ?? 0
        case .red, .green, .blue:
            leftmostX = [curves.red, curves.green, curves.blue]
                .compactMap { $0.sortedPoints.first?.x }
                .min() ?? 0
        }
        guard leftmostX > 0 else { return inputBlackPoint }
        return inputBlackPoint + leftmostX * (inputWhitePoint - inputBlackPoint)
    }

    /// Stretches either the RGB curve or the per-channel curves based on the active channel.
    /// Stretching both would double-apply the correction and darken the image.
    ///
    /// - RGB active → adjust only the RGB curve.
    /// - R / G / B active → adjust all three per-channel curves.
    private func stretchCurves(by x0: Double) {
        switch curves.activeChannel {
        case .rgb:
            curves.rgb.stretchFromBlackPoint(x0)
        case .red, .green, .blue:
            curves.red.stretchFromBlackPoint(x0)
            curves.green.stretchFromBlackPoint(x0)
            curves.blue.stretchFromBlackPoint(x0)
        }
    }

    func resetCurves() {
        recordUndoPoint()
        curves.reset()
        inputBlackPoint = 0.0
        inputWhitePoint = 1.0
        updatePreview()
    }

    // MARK: - Presets

    func capturePreset() -> Preset {
        Preset(
            id: UUID(),
            isNegative: isNegative,
            inputBlackPoint: inputBlackPoint,
            inputWhitePoint: inputWhitePoint,
            curves: CodableCurves(from: curves)
        )
    }

    func applyPreset(_ preset: Preset) {
        recordUndoPoint()
        isNegative      = preset.isNegative
        inputBlackPoint = preset.inputBlackPoint
        inputWhitePoint = preset.inputWhitePoint
        preset.curves.apply(to: curves)
    }

    /// Renders a small thumbnail for each preset against the current cached image.
    /// Thumbnails are stored in `presetThumbnails` keyed by preset id.
    func renderThumbnails(for presets: [Preset]) {
        guard let cachedImage else { return }
        let context          = ciContext
        let image            = cachedImage
        let currentNegative  = isNegative
        let targetWidth: CGFloat = 256   // 2× for Retina @2x

        Task.detached {
            let extent = image.extent
            let scale  = min(1.0, targetWidth / extent.width)
            var scaledImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            // Normalise origin to (0,0) after scaling
            scaledImage = scaledImage.transformed(by: CGAffineTransform(
                translationX: -scaledImage.extent.minX,
                y: -scaledImage.extent.minY
            ))

            var results: [UUID: CGImage] = [:]
            for preset in presets {
                var source = scaledImage
                // If this preset inverts differently from the current cache, compensate.
                if preset.isNegative != currentNegative {
                    source = source.applyingFilter("CIColorInvert")
                }
                let c = preset.curves
                let filtered = LUTGenerator.applyFilter(
                    to: source,
                    rgb: c.rgbCurve, red: c.redCurve,
                    green: c.greenCurve, blue: c.blueCurve,
                    blackPoint: preset.inputBlackPoint,
                    whitePoint: preset.inputWhitePoint
                )
                if let cg = context.createCGImage(
                    filtered,
                    from: filtered.extent,
                    format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
                ) {
                    results[preset.id] = cg
                }
            }
            await MainActor.run { self.presetThumbnails = results }
        }
    }

    // MARK: - Undo

    /// JSON snapshots of previous editing states, oldest first.
    /// Stored as Data so byte equality handles deduplication without needing Equatable.
    private var undoStack: [Data] = []
    private var lastSavedData: Data? = nil
    private let maxUndoSteps = 50
    @Published private(set) var canUndo = false

    /// Captures the current editing state and, if it has changed since the last
    /// recorded point, pushes the previous snapshot onto the undo stack.
    /// Does NOT write to disk — use `saveState()` for persistence.
    /// Called at the start of every drag gesture (via `onDragBegan` view callbacks)
    /// and directly before every one-shot mutation (rotate, crop, reset, preset apply, absorbBP).
    func recordUndoPoint() {
        guard sourceURL != nil else { return }
        guard let data = try? JSONEncoder().encode(currentEditingState()) else { return }
        guard data != lastSavedData else { return }   // nothing changed — skip
        if let previous = lastSavedData {
            undoStack.append(previous)
            if undoStack.count > maxUndoSteps { undoStack.removeFirst() }
            canUndo = true
        }
        lastSavedData = data
    }

    func undo() {
        guard let prevData = undoStack.popLast(),
              let prevState = try? JSONDecoder().decode(EditingState.self, from: prevData)
        else { return }
        canUndo = !undoStack.isEmpty
        // Update lastSavedData to the state we're restoring so the next debounced
        // saveState() sees no change and doesn't re-push it onto the stack.
        lastSavedData = prevData
        applyEditingState(prevState)
        // Write restored state to sidecar immediately.
        guard let url = sourceURL else { return }
        try? prevData.write(to: url.curvelabSidecar)
    }

    /// Applies a previously saved EditingState, rebuilding the pixel buffer only when
    /// rotation, inversion, or crop changed (levels/curves only need a preview update).
    private func applyEditingState(_ state: EditingState) {
        let prevRotation  = rotationAngle
        let prevNegative  = isNegative
        let prevCropRect  = appliedCropRect

        suppressCacheRebuild = true
        rotationAngle   = state.rotation
        isNegative      = state.isNegative
        appliedCropRect = state.appliedCropRect?.cgRect
        inputBlackPoint = state.inputBlackPoint
        inputWhitePoint = state.inputWhitePoint
        state.apply(to: curves)
        suppressCacheRebuild = false

        let needsCacheRebuild = rotationAngle   != prevRotation
                             || isNegative      != prevNegative
                             || appliedCropRect != prevCropRect
        if needsCacheRebuild {
            rebuildCache()
        } else {
            updatePreview()
        }
    }

    // MARK: - Sidecar save / load

    /// Snapshot of all current editing decisions.
    /// Single source of truth — used by `recordUndoPoint()`, `saveState()`, and `capturePreset()`.
    private func currentEditingState() -> EditingState {
        EditingState(
            rotation: rotationAngle,
            isNegative: isNegative,
            appliedCropRect: appliedCropRect,
            inputBlackPoint: inputBlackPoint,
            inputWhitePoint: inputWhitePoint,
            curves: curves
        )
    }

    func saveState() {
        guard let url = sourceURL else {
            print("[CurveLab] saveState: no sourceURL set")
            return
        }
        guard let data = try? JSONEncoder().encode(currentEditingState()) else { return }
        lastSavedData = data

        do {
            try data.write(to: url.curvelabSidecar)
            print("[CurveLab] Saved state to \(url.curvelabSidecar.path)")
        } catch {
            print("[CurveLab] saveState failed: \(error)")
        }
    }

}
