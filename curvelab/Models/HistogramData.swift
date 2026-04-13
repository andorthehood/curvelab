import CoreImage
import Accelerate

struct HistogramData {
    let red: [Float]    // 256 normalized values (0..1)
    let green: [Float]
    let blue: [Float]
    let luminance: [Float]

    static func compute(from image: CIImage) -> HistogramData? {
        let context = CIContext(options: [.useSoftwareRenderer: false])

        // Scale down for faster histogram computation
        let maxDim: CGFloat = 1024
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1.0, maxDim / max(extent.width, extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent

        let width = Int(scaledExtent.width)
        let height = Int(scaledExtent.height)
        guard width > 0, height > 0 else { return nil }

        // Render to bitmap
        guard let cgImage = context.createCGImage(scaled, from: scaledExtent) else { return nil }

        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow
        let pixelCount = width * height

        var redBins = [Float](repeating: 0, count: 256)
        var greenBins = [Float](repeating: 0, count: 256)
        var blueBins = [Float](repeating: 0, count: 256)
        var lumBins = [Float](repeating: 0, count: 256)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Int(ptr[offset])
                let g = Int(ptr[offset + 1])
                let b = Int(ptr[offset + 2])

                redBins[r] += 1
                greenBins[g] += 1
                blueBins[b] += 1

                // Luminance: 0.299R + 0.587G + 0.114B
                let lum = Int(0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b))
                lumBins[min(255, lum)] += 1
            }
        }

        // Normalize to 0..1
        let maxR = redBins.max() ?? 1
        let maxG = greenBins.max() ?? 1
        let maxB = blueBins.max() ?? 1
        let maxL = lumBins.max() ?? 1

        return HistogramData(
            red: redBins.map { $0 / maxR },
            green: greenBins.map { $0 / maxG },
            blue: blueBins.map { $0 / maxB },
            luminance: lumBins.map { $0 / maxL }
        )
    }
}
