import SwiftUI
import CoreImage
import CoreVideo
import Combine
import UniformTypeIdentifiers

@MainActor
class ImageViewModel: ObservableObject {
    @Published var originalImage: CIImage?
    @Published var previewImage: CIImage?
    @Published var curves = CurveModel()
    @Published var isLoading = false
    @Published var fileName = "CurveLab"
    @Published var histogram: HistogramData?
    @Published var outputHistogram: HistogramData?
    @Published var rotationAngle: Double = 0
    @Published var hdrPreview = false
    @Published var cropState: CropState = CropState(rect: .zero, isActive: false)
    @Published var showCropOverlay = false
    @Published var isNegative = false

    var imageSize: CGSize {
        guard let ext = cachedImage?.extent else { return .zero }
        return CGSize(width: ext.width, height: ext.height)
    }

    var hasCachedImage: Bool { cachedImage != nil }

    private var cachedImage: CIImage?
    private var appliedCropRect: CGRect? = nil
    private var sourceURL: URL? = nil

    // Suppresses the $isNegative → rebuildCache sink during import
    // so we don't rebuild twice when loading a sidecar.
    private var suppressCacheRebuild = false

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
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
                self.rebuildCache(invert: invert)
            }
            .store(in: &cancellables)
    }

    // MARK: - Import

    func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rawImage, .tiff, .png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isLoading = true
        fileName = url.deletingPathExtension().lastPathComponent
        sourceURL = url

        // Load sidecar if one exists
        let state = (try? Data(contentsOf: url.curvelabSidecar))
            .flatMap { try? JSONDecoder().decode(EditingState.self, from: $0) }

        // Capture values for the detached task
        let rotation    = state?.rotation    ?? 0
        let invertNeg   = state?.isNegative  ?? false
        let cropRect    = state?.appliedCropRect?.cgRect
        let context     = ciContext

        suppressCacheRebuild = true

        Task.detached {
            guard let decoded = DNGLoader.load(url: url) else {
                await MainActor.run { self.isLoading = false; self.suppressCacheRebuild = false }
                return
            }

            let base = Self.buildBase(from: decoded, rotation: rotation, invert: invertNeg)
            let imageToCache = Self.applyCrop(cropRect, to: base)
            let cached   = Self.renderToBuffer(imageToCache, context: context)
            let histData = cached.flatMap { HistogramData.compute(from: $0, context: context) }

            await MainActor.run {
                self.originalImage   = decoded
                self.cachedImage     = cached
                self.rotationAngle   = rotation
                self.isNegative      = invertNeg
                self.appliedCropRect = cropRect
                self.histogram       = histData
                self.cropState       = cached.map {
                    cropRect != nil
                        ? CropState(rect: $0.extent, isActive: true)
                        : CropState.full(for: $0)
                } ?? CropState(rect: .zero, isActive: false)
                self.showCropOverlay = false

                if let state { state.apply(to: self.curves) } else { self.curves.reset() }

                self.suppressCacheRebuild = false
                self.updatePreview()
                self.isLoading = false
                self.saveState()
            }
        }
    }

    // MARK: - Preview

    func updatePreview() {
        guard let cachedImage else {
            previewImage = nil
            outputHistogram = nil
            return
        }
        let preview = LUTGenerator.applyFilter(to: cachedImage, curves: curves)
        previewImage = preview
        let context = ciContext
        Task.detached {
            let histData = HistogramData.compute(from: preview, context: context)
            await MainActor.run { self.outputHistogram = histData }
        }
    }

    // MARK: - Rotation

    func rotateLeft() {
        rotationAngle = (rotationAngle - 90).truncatingRemainder(dividingBy: 360)
        if rotationAngle < 0 { rotationAngle += 360 }
        appliedCropRect = nil
        rebuildCache()
    }

    func rotateRight() {
        rotationAngle = (rotationAngle + 90).truncatingRemainder(dividingBy: 360)
        appliedCropRect = nil
        rebuildCache()
    }

    // MARK: - Cache rebuild

    /// Returns originalImage with rotation + optional inversion applied (no crop).
    private func preparedBase(invert: Bool? = nil) -> CIImage? {
        guard let originalImage else { return nil }
        return Self.buildBase(from: originalImage, rotation: rotationAngle,
                              invert: invert ?? isNegative)
    }

    private func rebuildCache(invert: Bool? = nil) {
        guard let base = preparedBase(invert: invert) else { return }
        isLoading = true

        let imageToCache = Self.applyCrop(appliedCropRect, to: base)
        let hasCrop = appliedCropRect != nil
        let context = ciContext

        Task.detached {
            let cached   = Self.renderToBuffer(imageToCache, context: context)
            let histData = cached.flatMap { HistogramData.compute(from: $0, context: context) }
            await MainActor.run {
                self.cachedImage = cached
                self.histogram   = histData
                self.cropState   = cached.map {
                    hasCrop ? CropState(rect: $0.extent, isActive: true) : CropState.full(for: $0)
                } ?? CropState(rect: .zero, isActive: false)
                self.updatePreview()
                self.isLoading = false
                self.saveState()
            }
        }
    }

    // MARK: - Crop

    func applyCrop() {
        guard let base = preparedBase() else { return }
        let clampedState = cropState.clamped(to: base.extent)
        let imageToCache = Self.applyCrop(clampedState.rect, to: base)
        appliedCropRect  = clampedState.rect
        isLoading = true
        let context = ciContext
        Task.detached {
            let cached   = Self.renderToBuffer(imageToCache, context: context)
            let histData = cached.flatMap { HistogramData.compute(from: $0, context: context) }
            await MainActor.run {
                self.cachedImage = cached
                self.histogram   = histData
                self.cropState   = cached.map { CropState(rect: $0.extent, isActive: true) }
                    ?? CropState(rect: .zero, isActive: false)
                self.updatePreview()
                self.isLoading = false
                self.saveState()
            }
        }
    }

    func resetCrop() {
        guard let base = preparedBase() else { return }
        appliedCropRect = nil
        isLoading = true
        let context = ciContext
        Task.detached {
            let cached   = Self.renderToBuffer(base, context: context)
            let histData = cached.flatMap { HistogramData.compute(from: $0, context: context) }
            await MainActor.run {
                self.cachedImage = cached
                self.histogram   = histData
                self.cropState   = cached.map { CropState.full(for: $0) }
                    ?? CropState(rect: .zero, isActive: false)
                self.updatePreview()
                self.isLoading = false
                self.saveState()
            }
        }
    }

    // MARK: - Curves

    func resetCurves() {
        curves.reset()
        updatePreview()
    }

    // MARK: - Export

    func exportJPG() {
        guard let previewImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "\(fileName)_edited.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isLoading = true
        let imageToExport = previewImage
        let context = ciContext
        Task.detached {
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            try? context.writeJPEGRepresentation(
                of: imageToExport, to: url, colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
            )
            await MainActor.run { self.isLoading = false }
        }
    }

    // MARK: - Sidecar save / load

    func saveState() {
        guard let url = sourceURL else {
            print("[CurveLab] saveState: no sourceURL set")
            return
        }
        let sidecar = url.curvelabSidecar
        let state = EditingState(
            rotation: rotationAngle,
            isNegative: isNegative,
            appliedCropRect: appliedCropRect,
            curves: curves
        )
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: sidecar)
            print("[CurveLab] Saved state to \(sidecar.path)")
        } catch {
            print("[CurveLab] saveState failed: \(error)")
        }
    }

    // MARK: - Static helpers (nonisolated — safe to call from Task.detached)

    private nonisolated static func buildBase(from image: CIImage,
                                              rotation: Double,
                                              invert: Bool) -> CIImage {
        let rotated = rotatedImage(image, angle: rotation)
        return invert ? rotated.applyingFilter("CIColorInvert") : rotated
    }

    private nonisolated static func rotatedImage(_ image: CIImage, angle: Double) -> CIImage {
        guard angle != 0 else { return image }
        let radians = angle * .pi / 180
        let extent  = image.extent
        let cx = extent.midX, cy = extent.midY
        let rotated = image
            .transformed(by: CGAffineTransform(translationX: -cx, y: -cy))
            .transformed(by: CGAffineTransform(rotationAngle: CGFloat(radians)))
            .transformed(by: CGAffineTransform(translationX: cx, y: cy))
        let ne = rotated.extent
        return rotated.transformed(by: CGAffineTransform(translationX: -ne.minX, y: -ne.minY))
    }

    /// Crops and normalises origin if rect is provided; returns image unchanged otherwise.
    private nonisolated static func applyCrop(_ rect: CGRect?, to image: CIImage) -> CIImage {
        guard let rect, rect.width >= CropState.minimumSize,
              rect.height >= CropState.minimumSize else { return image }
        let cropped = image.cropped(to: rect)
        return cropped.transformed(by: CGAffineTransform(
            translationX: -cropped.extent.minX,
            y: -cropped.extent.minY
        ))
    }

    private nonisolated static func renderToBuffer(_ image: CIImage,
                                                   context: CIContext) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let width = Int(extent.width), height = Int(extent.height)

        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_128RGBAFloat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_128RGBAFloat,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        context.render(image, to: buffer,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        return CIImage(cvPixelBuffer: buffer)
    }

    // Instance wrapper used by preparedBase (reads self.rotationAngle)
    private func rotateImage(_ image: CIImage) -> CIImage {
        Self.rotatedImage(image, angle: rotationAngle)
    }
}
