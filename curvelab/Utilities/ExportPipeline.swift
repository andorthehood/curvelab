import CoreImage
import ImageIO

enum ExportPipeline {
    struct IntegerMaster {
        let width: Int
        let height: Int
        let pixels: [UInt16]

        var rowBytes: Int {
            width * MemoryLayout<UInt16>.size * 4
        }
    }

    static func makeUneditedExportImage(from originalImage: CIImage,
                                        rotation: Double,
                                        cropRect: CGRect?) -> CIImage {
        let invertedBase = RenderEngine.buildBase(from: originalImage, rotation: rotation, invert: true)
        return RenderEngine.crop(cropRect, to: invertedBase)
    }

    static func writeJPEG(previewImage: CIImage,
                          linear: Bool,
                          to url: URL) {
        let exportContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!
        ])
        let outputColorSpace = CGColorSpace(name: linear
            ? CGColorSpace.linearSRGB
            : CGColorSpace.sRGB)!
        guard let cgImage = exportContext.createCGImage(
            previewImage,
            from: previewImage.extent,
            format: .RGBA8,
            colorSpace: outputColorSpace
        ) else { return }

        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cgImage,
                [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
    }

    static func makeIntegerMaster(from image: CIImage) -> IntegerMaster? {
        let context = CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!
        ])
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        let rowBytes = width * MemoryLayout<UInt16>.size * 4
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(
                image,
                toBitmap: bytes.baseAddress!,
                rowBytes: rowBytes,
                bounds: extent,
                format: .RGBA16,
                colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!
            )
        }
        return IntegerMaster(width: width, height: height, pixels: pixels)
    }

    static func write16BitTIFF(master: IntegerMaster, to url: URL) {
        guard let cgImage = make16BitCGImage(from: master),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else {
            return
        }

        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func make16BitCGImage(from master: IntegerMaster) -> CGImage? {
        let data = Data(bytes: master.pixels, count: master.pixels.count * MemoryLayout<UInt16>.size)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: master.width,
            height: master.height,
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            bytesPerRow: master.rowBytes,
            space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
            bitmapInfo: [
                CGBitmapInfo.byteOrder16Little,
                CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
            ],
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

}
