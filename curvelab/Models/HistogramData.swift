import CoreImage

struct HistogramData {
    let red: [Float]    // 256 normalized values (0..1)
    let green: [Float]
    let blue: [Float]
    let luminance: [Float]

    // Raw unnormalized counts for remapping through curves
    let rawRed: [Float]
    let rawGreen: [Float]
    let rawBlue: [Float]

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

        // Detect byte order — macOS CIContext often returns BGRA
        let alphaInfo = cgImage.alphaInfo
        let byteOrder = cgImage.bitmapInfo.intersection(.byteOrderMask)
        let isBGRA = (byteOrder == .byteOrder32Little) ||
                     (byteOrder == .byteOrderDefault && alphaInfo == .premultipliedFirst)
        let rOff = isBGRA ? 2 : 0
        let gOff = 1
        let bOff = isBGRA ? 0 : 2

        var redBins = [Float](repeating: 0, count: 256)
        var greenBins = [Float](repeating: 0, count: 256)
        var blueBins = [Float](repeating: 0, count: 256)
        var lumBins = [Float](repeating: 0, count: 256)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Int(ptr[offset + rOff])
                let g = Int(ptr[offset + gOff])
                let b = Int(ptr[offset + bOff])

                redBins[r] += 1
                greenBins[g] += 1
                blueBins[b] += 1

                let lum = Int(0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b))
                lumBins[min(255, lum)] += 1
            }
        }

        let maxR = redBins.max() ?? 1
        let maxG = greenBins.max() ?? 1
        let maxB = blueBins.max() ?? 1
        let maxL = lumBins.max() ?? 1

        return HistogramData(
            red: redBins.map { $0 / maxR },
            green: greenBins.map { $0 / maxG },
            blue: blueBins.map { $0 / maxB },
            luminance: lumBins.map { $0 / maxL },
            rawRed: redBins,
            rawGreen: greenBins,
            rawBlue: blueBins
        )
    }

    /// Remap this histogram through the given curves to produce the output histogram.
    func remapped(through curves: CurveModel) -> HistogramData {
        let rgbSpline = curves.rgb.spline()
        let redSpline = curves.red.spline()
        let greenSpline = curves.green.spline()
        let blueSpline = curves.blue.spline()

        var outRed = [Float](repeating: 0, count: 256)
        var outGreen = [Float](repeating: 0, count: 256)
        var outBlue = [Float](repeating: 0, count: 256)

        for i in 0..<256 {
            let t = Double(i) / 255.0

            // Apply RGB composite then per-channel, same order as LUTGenerator
            let rOut = redSpline.evaluate(at: rgbSpline.evaluate(at: t))
            let gOut = greenSpline.evaluate(at: rgbSpline.evaluate(at: t))
            let bOut = blueSpline.evaluate(at: rgbSpline.evaluate(at: t))

            let rBin = min(255, max(0, Int(rOut * 255.0)))
            let gBin = min(255, max(0, Int(gOut * 255.0)))
            let bBin = min(255, max(0, Int(bOut * 255.0)))

            outRed[rBin] += rawRed[i]
            outGreen[gBin] += rawGreen[i]
            outBlue[bBin] += rawBlue[i]
        }

        // Compute luminance from remapped channels
        var outLum = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let lum = 0.299 * outRed[i] + 0.587 * outGreen[i] + 0.114 * outBlue[i]
            outLum[i] = lum
        }

        let maxR = outRed.max() ?? 1
        let maxG = outGreen.max() ?? 1
        let maxB = outBlue.max() ?? 1
        let maxL = outLum.max() ?? 1

        return HistogramData(
            red: outRed.map { $0 / maxR },
            green: outGreen.map { $0 / maxG },
            blue: outBlue.map { $0 / maxB },
            luminance: outLum.map { $0 / maxL },
            rawRed: outRed,
            rawGreen: outGreen,
            rawBlue: outBlue
        )
    }
}
