import CoreImage
import CoreVideo

/// Stateless pixel-pipeline operations.
///
/// These are the building blocks that turn a decoded source `CIImage` into
/// a fully-rendered float32 buffer the UI can display. All methods are pure
/// (no `@MainActor`, no SwiftUI) and safe to call from `Task.detached`.
///
/// Called exclusively by `RenderPipeline` from its off-actor detached task.
enum RenderEngine {

    // MARK: - Geometry

    /// Applies rotation, then optionally inverts colors. No crop.
    static func buildBase(from image: CIImage,
                          rotation: Double,
                          invert: Bool) -> CIImage {
        let rotated = rotate(image, angle: rotation)
        return invert ? rotated.applyingFilter("CIColorInvert") : rotated
    }

    /// Rotates around the image center and normalises the origin to (0, 0).
    /// Returns the input unchanged when `angle == 0`.
    static func rotate(_ image: CIImage, angle: Double) -> CIImage {
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

    /// Crops and normalises origin if `rect` is provided and meets the minimum
    /// size. Returns the image unchanged otherwise.
    static func crop(_ rect: CGRect?, to image: CIImage) -> CIImage {
        guard let rect, rect.width >= CropState.minimumSize,
              rect.height >= CropState.minimumSize else { return image }
        let cropped = image.cropped(to: rect)
        return cropped.transformed(by: CGAffineTransform(
            translationX: -cropped.extent.minX,
            y: -cropped.extent.minY
        ))
    }

    // MARK: - Rendering

    /// Renders `image` into a fresh float32 `CVPixelBuffer` and returns it
    /// wrapped as a `CIImage`. The buffer lives in extendedLinearSRGB so the
    /// untagged float values round-trip correctly to the Metal preview.
    ///
    /// Returns `nil` when the input has zero extent.
    static func renderToBuffer(_ image: CIImage,
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
}
