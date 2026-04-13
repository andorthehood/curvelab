import CoreImage

enum LUTGenerator {
    static let cubeSize = 33

    static func buildCubeData(curves: CurveModel) -> Data {
        let size = cubeSize
        let rgbSpline = curves.rgb.spline()
        let redSpline = curves.red.spline()
        let greenSpline = curves.green.spline()
        let blueSpline = curves.blue.spline()

        let count = size * size * size * 4
        var floats = [Float](repeating: 0, count: count)

        var idx = 0
        // CIColorCube order: blue outermost, green middle, red innermost
        for bIdx in 0..<size {
            let bNorm = Double(bIdx) / Double(size - 1)
            for gIdx in 0..<size {
                let gNorm = Double(gIdx) / Double(size - 1)
                for rIdx in 0..<size {
                    let rNorm = Double(rIdx) / Double(size - 1)

                    // Apply composite RGB curve first
                    let rAfterRGB = rgbSpline.evaluate(at: rNorm)
                    let gAfterRGB = rgbSpline.evaluate(at: gNorm)
                    let bAfterRGB = rgbSpline.evaluate(at: bNorm)

                    // Then apply per-channel curves
                    floats[idx]     = Float(redSpline.evaluate(at: rAfterRGB))
                    floats[idx + 1] = Float(greenSpline.evaluate(at: gAfterRGB))
                    floats[idx + 2] = Float(blueSpline.evaluate(at: bAfterRGB))
                    floats[idx + 3] = 1.0

                    idx += 4
                }
            }
        }

        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func applyFilter(to image: CIImage, curves: CurveModel) -> CIImage {
        let cubeData = buildCubeData(curves: curves)

        guard let filter = CIFilter(name: "CIColorCube") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(cubeSize, forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")

        return filter.outputImage ?? image
    }
}
