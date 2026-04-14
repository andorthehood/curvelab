import CoreImage

enum LUTGenerator {
    static let cubeSize = 33

    static func buildCubeData(curves: CurveModel,
                              blackPoint: Double = 0,
                              whitePoint: Double = 1) -> Data {
        buildCubeData(rgb: curves.rgb, red: curves.red,
                      green: curves.green, blue: curves.blue,
                      blackPoint: blackPoint, whitePoint: whitePoint)
    }

    static func applyFilter(to image: CIImage, curves: CurveModel,
                            blackPoint: Double = 0, whitePoint: Double = 1) -> CIImage {
        let cubeData = buildCubeData(curves: curves, blackPoint: blackPoint, whitePoint: whitePoint)

        guard let filter = CIFilter(name: "CIColorCube") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(cubeSize, forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")

        return filter.outputImage ?? image
    }

    // MARK: - ChannelCurve overloads (value types — safe to call from Task.detached)

    static func buildCubeData(rgb: ChannelCurve, red: ChannelCurve,
                               green: ChannelCurve, blue: ChannelCurve,
                               blackPoint: Double = 0, whitePoint: Double = 1) -> Data {
        let size = cubeSize
        let rgbSpline   = rgb.spline()
        let redSpline   = red.spline()
        let greenSpline = green.spline()
        let blueSpline  = blue.spline()

        let count = size * size * size * 4
        var floats = [Float](repeating: 0, count: count)

        let range = whitePoint - blackPoint

        var idx = 0
        for bIdx in 0..<size {
            let bNorm = Double(bIdx) / Double(size - 1)
            for gIdx in 0..<size {
                let gNorm = Double(gIdx) / Double(size - 1)
                for rIdx in 0..<size {
                    let rNorm = Double(rIdx) / Double(size - 1)

                    let rLeveled = range > 0 ? max(0, min(1, (rNorm - blackPoint) / range)) : 0
                    let gLeveled = range > 0 ? max(0, min(1, (gNorm - blackPoint) / range)) : 0
                    let bLeveled = range > 0 ? max(0, min(1, (bNorm - blackPoint) / range)) : 0

                    let rAfterRGB = rgbSpline.evaluate(at: rLeveled)
                    let gAfterRGB = rgbSpline.evaluate(at: gLeveled)
                    let bAfterRGB = rgbSpline.evaluate(at: bLeveled)

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

    static func applyFilter(to image: CIImage, rgb: ChannelCurve, red: ChannelCurve,
                             green: ChannelCurve, blue: ChannelCurve,
                             blackPoint: Double = 0, whitePoint: Double = 1) -> CIImage {
        let cubeData = buildCubeData(rgb: rgb, red: red, green: green, blue: blue,
                                     blackPoint: blackPoint, whitePoint: whitePoint)
        guard let filter = CIFilter(name: "CIColorCube") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(cubeSize, forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")
        return filter.outputImage ?? image
    }
}
