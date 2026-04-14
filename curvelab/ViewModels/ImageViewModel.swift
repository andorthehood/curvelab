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
    @Published var rotationAngle: Double = 0 // degrees: 0, 90, 180, 270
    @Published var hdrPreview = false
    @Published var cropState: CropState = CropState(rect: .zero, isActive: false)
    @Published var showCropOverlay = false

    var imageSize: CGSize {
        guard let ext = cachedImage?.extent else { return .zero }
        return CGSize(width: ext.width, height: ext.height)
    }

    var hasCachedImage: Bool { cachedImage != nil }

    // Cached pixel buffer of the (possibly rotated) decoded original.
    // Curve adjustments apply only to this — no DNG re-decode on every drag.
    private var cachedImage: CIImage?

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var cancellables = Set<AnyCancellable>()

    init() {
        curves.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePreview()
            }
            .store(in: &cancellables)
    }

    func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rawImage, .tiff, .png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isLoading = true
        fileName = url.deletingPathExtension().lastPathComponent

        let context = ciContext
        Task.detached {
            guard let decoded = DNGLoader.load(url: url) else {
                await MainActor.run { self.isLoading = false }
                return
            }
            // Render decoded DNG into a float32 pixel buffer once
            let cached = Self.renderToBuffer(decoded, context: context)
            let histData = cached.flatMap { HistogramData.compute(from: $0) }
            await MainActor.run {
                self.originalImage = decoded
                self.cachedImage = cached
                self.rotationAngle = 0
                self.histogram = histData
                self.curves.reset()
                self.cropState = cached.map { CropState.full(for: $0) }
                    ?? CropState(rect: .zero, isActive: false)
                self.showCropOverlay = false
                self.updatePreview()
                self.isLoading = false
            }
        }
    }

    func updatePreview() {
        guard let cachedImage else {
            previewImage = nil
            return
        }
        previewImage = LUTGenerator.applyFilter(to: cachedImage, curves: curves)
    }

    func rotateLeft() {
        rotationAngle = (rotationAngle - 90).truncatingRemainder(dividingBy: 360)
        if rotationAngle < 0 { rotationAngle += 360 }
        rebuildCache()
    }

    func rotateRight() {
        rotationAngle = (rotationAngle + 90).truncatingRemainder(dividingBy: 360)
        rebuildCache()
    }

    private func rebuildCache() {
        guard let originalImage else { return }
        isLoading = true
        let rotated = rotateImage(originalImage)
        let context = ciContext
        Task.detached {
            let cached = Self.renderToBuffer(rotated, context: context)
            await MainActor.run {
                self.cachedImage = cached
                self.cropState = cached.map { CropState.full(for: $0) }
                    ?? CropState(rect: .zero, isActive: false)
                self.updatePreview()
                self.isLoading = false
            }
        }
    }

    private func rotateImage(_ image: CIImage) -> CIImage {
        guard rotationAngle != 0 else { return image }
        let radians = rotationAngle * .pi / 180
        let extent = image.extent
        let cx = extent.midX
        let cy = extent.midY
        let rotated = image
            .transformed(by: CGAffineTransform(translationX: -cx, y: -cy))
            .transformed(by: CGAffineTransform(rotationAngle: CGFloat(radians)))
            .transformed(by: CGAffineTransform(translationX: cx, y: cy))
        let newExtent = rotated.extent
        return rotated.transformed(by: CGAffineTransform(
            translationX: -newExtent.minX,
            y: -newExtent.minY
        ))
    }

    /// Renders a CIImage into a float32 CVPixelBuffer and returns a CIImage backed by it.
    /// This materialises the lazy CoreImage chain (including DNG decode) into actual pixels.
    private nonisolated static func renderToBuffer(_ image: CIImage, context: CIContext) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let width = Int(extent.width)
        let height = Int(extent.height)

        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_128RGBAFloat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_128RGBAFloat, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        context.render(image, to: buffer,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))

        return CIImage(cvPixelBuffer: buffer)
    }

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
                of: imageToExport,
                to: url,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
            )
            await MainActor.run { self.isLoading = false }
        }
    }

    func applyCrop() {
        guard let originalImage else { return }
        // Clamp the crop rect to the current image extent before using it
        let clampedState = cropState.clamped(to: originalImage.extent)
        let cropped = originalImage.cropped(to: clampedState.rect)
        // Normalise origin to (0,0) — required before renderToBuffer
        let normalised = cropped.transformed(by: CGAffineTransform(
            translationX: -cropped.extent.minX,
            y: -cropped.extent.minY
        ))
        isLoading = true
        let context = ciContext
        Task.detached {
            let cached = Self.renderToBuffer(normalised, context: context)
            let histData = cached.flatMap { HistogramData.compute(from: $0) }
            await MainActor.run {
                self.cachedImage = cached
                self.histogram = histData
                self.cropState = cached.map { CropState(rect: $0.extent, isActive: true) }
                    ?? CropState(rect: .zero, isActive: false)
                self.updatePreview()
                self.isLoading = false
            }
        }
    }

    func resetCrop() {
        guard let originalImage else { return }
        isLoading = true
        let context = ciContext
        Task.detached {
            let cached = Self.renderToBuffer(originalImage, context: context)
            let histData = cached.flatMap { HistogramData.compute(from: $0) }
            await MainActor.run {
                self.cachedImage = cached
                self.histogram = histData
                self.cropState = cached.map { CropState.full(for: $0) }
                    ?? CropState(rect: .zero, isActive: false)
                self.updatePreview()
                self.isLoading = false
            }
        }
    }

    func resetCurves() {
        curves.reset()
        updatePreview()
    }
}
