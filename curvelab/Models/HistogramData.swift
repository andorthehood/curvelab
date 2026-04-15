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

    static func compute(from image: CIImage, context: CIContext? = nil) -> HistogramData? {
        let context = context ?? CIContext(options: [.useSoftwareRenderer: false])

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

    /// Returns a copy with the first and last bins zeroed out and the remaining
    /// bins re-normalised to their own peak.  Use this to prevent clipping
    /// pile-up (from input levels) from dominating the histogram display scale.
    var withClipEndsExcluded: HistogramData {
        func strip(normalized: [Float], raw: [Float]) -> (norm: [Float], raw: [Float]) {
            var n = normalized; var r = raw
            n[0] = 0; n[n.count - 1] = 0
            r[0] = 0; r[r.count - 1] = 0
            let m = n.max() ?? 1
            return (m > 0 ? n.map { $0 / m } : n, r)
        }
        let r = strip(normalized: red,   raw: rawRed)
        let g = strip(normalized: green, raw: rawGreen)
        let b = strip(normalized: blue,  raw: rawBlue)
        var lum = luminance; lum[0] = 0; lum[lum.count - 1] = 0
        let ml = lum.max() ?? 1
        return HistogramData(
            red:       r.norm, green: g.norm, blue: b.norm,
            luminance: ml > 0 ? lum.map { $0 / ml } : lum,
            rawRed:    r.raw,  rawGreen: g.raw, rawBlue: b.raw
        )
    }

    /// Remaps every bin through the input-levels transform
    ///     t' = clamp((t - blackPoint) / (whitePoint - blackPoint), 0, 1)
    /// producing a post-levels histogram from a pre-levels one. Pure CPU, no
    /// pixel data — designed to be called on every curve/levels frame.
    ///
    /// Matches `LUTGenerator.buildCubeData`'s levels formula exactly: when
    /// `range <= 0`, every bin collapses to 0 (same behaviour the LUT uses).
    ///
    /// Uses area distribution (see `distribute`) so a stretch (range < 1)
    /// doesn't leave gaps between non-adjacent output bins; a pixel walk
    /// naturally produces smooth output, and this bin-remap matches it by
    /// treating each source bin `i` as the half-open interval
    /// `[i/256, (i+1)/256)` and spreading its count across every output
    /// bin the transformed interval overlaps.
    func remapped(throughLevels blackPoint: Double, whitePoint: Double) -> HistogramData {
        let range = whitePoint - blackPoint
        func leveled(_ t: Double) -> Double {
            range > 0 ? max(0, min(1, (t - blackPoint) / range)) : 0
        }

        var outRed   = [Float](repeating: 0, count: 256)
        var outGreen = [Float](repeating: 0, count: 256)
        var outBlue  = [Float](repeating: 0, count: 256)

        for i in 0..<256 {
            let t0 = Double(i)     / 256.0
            let t1 = Double(i + 1) / 256.0
            let o0 = leveled(t0)
            let o1 = leveled(t1)

            Self.distribute(count: rawRed[i],   from: o0, to: o1, into: &outRed)
            Self.distribute(count: rawGreen[i], from: o0, to: o1, into: &outGreen)
            Self.distribute(count: rawBlue[i],  from: o0, to: o1, into: &outBlue)
        }

        return Self.assemble(outRed: outRed, outGreen: outGreen, outBlue: outBlue)
    }

    /// Remap this histogram through the given curves to produce the output histogram.
    /// See `remapped(throughLevels:whitePoint:)` for notes on area distribution —
    /// same approach applies here, with the added wrinkle that curves aren't
    /// guaranteed to be monotonic (users can invert or fold them), so
    /// `distribute` accepts `from >= to` and flips internally.
    func remapped(through curves: CurveModel) -> HistogramData {
        let rgbSpline   = curves.rgb.spline()
        let redSpline   = curves.red.spline()
        let greenSpline = curves.green.spline()
        let blueSpline  = curves.blue.spline()

        var outRed   = [Float](repeating: 0, count: 256)
        var outGreen = [Float](repeating: 0, count: 256)
        var outBlue  = [Float](repeating: 0, count: 256)

        for i in 0..<256 {
            let t0 = Double(i)     / 256.0
            let t1 = Double(i + 1) / 256.0

            // Apply RGB composite then per-channel, same order as LUTGenerator.
            let rgb0 = rgbSpline.evaluate(at: t0)
            let rgb1 = rgbSpline.evaluate(at: t1)

            let r0 = redSpline.evaluate(at: rgb0)
            let r1 = redSpline.evaluate(at: rgb1)
            Self.distribute(count: rawRed[i], from: r0, to: r1, into: &outRed)

            let g0 = greenSpline.evaluate(at: rgb0)
            let g1 = greenSpline.evaluate(at: rgb1)
            Self.distribute(count: rawGreen[i], from: g0, to: g1, into: &outGreen)

            let b0 = blueSpline.evaluate(at: rgb0)
            let b1 = blueSpline.evaluate(at: rgb1)
            Self.distribute(count: rawBlue[i], from: b0, to: b1, into: &outBlue)
        }

        return Self.assemble(outRed: outRed, outGreen: outGreen, outBlue: outBlue)
    }

    // MARK: - Remap helpers

    /// Distributes `count` across the bins of `out` in proportion to how much
    /// of each integer bin `[b, b+1)` is covered by the output interval
    /// `[lo, hi)` in *bin-index space*. `from` and `hi` are provided in
    /// normalised [0, 1] value space and converted internally; ordering is
    /// normalised so non-monotonic transforms work.
    ///
    /// This is the histogram analogue of "area sampling" — a source bin that
    /// stretches across multiple output bins contributes to each in proportion
    /// to coverage, preventing the picket-fence effect that point-binning
    /// (`Int(t * N)`) produces when the transform's slope is not exactly 1.
    /// Collapses to a single bin when the interval degenerates.
    private static func distribute(count: Float,
                                   from valueLow: Double, to valueHigh: Double,
                                   into out: inout [Float]) {
        let binCount = out.count
        var lo = min(valueLow, valueHigh)
        var hi = max(valueLow, valueHigh)
        lo = max(0, min(1, lo))
        hi = max(0, min(1, hi))

        // Degenerate interval — dump everything into the bin that contains it.
        if hi - lo < 1e-12 {
            let bin = min(binCount - 1, max(0, Int(lo * Double(binCount))))
            out[bin] += count
            return
        }

        // Convert to output-bin-index space.
        let loIdx = lo * Double(binCount)
        let hiIdx = hi * Double(binCount)
        let span  = hiIdx - loIdx

        let startBin = max(0, Int(floor(loIdx)))
        let endBin   = min(binCount - 1, Int(ceil(hiIdx)) - 1)
        guard startBin <= endBin else { return }

        for b in startBin...endBin {
            let binLo   = Double(b)
            let binHi   = Double(b + 1)
            let overlap = min(hiIdx, binHi) - max(loIdx, binLo)
            if overlap > 0 {
                out[b] += Float(Double(count) * overlap / span)
            }
        }
    }

    /// Builds a normalised `HistogramData` from three raw channel bin arrays.
    /// Derives luminance from the remapped channels and handles empty channels
    /// (max == 0) without producing NaNs.
    private static func assemble(outRed: [Float],
                                 outGreen: [Float],
                                 outBlue: [Float]) -> HistogramData {
        var outLum = [Float](repeating: 0, count: outRed.count)
        for i in 0..<outRed.count {
            outLum[i] = 0.299 * outRed[i] + 0.587 * outGreen[i] + 0.114 * outBlue[i]
        }

        func norm(_ bins: [Float]) -> [Float] {
            let m = bins.max() ?? 0
            return m > 0 ? bins.map { $0 / m } : bins
        }

        return HistogramData(
            red:       norm(outRed),
            green:     norm(outGreen),
            blue:      norm(outBlue),
            luminance: norm(outLum),
            rawRed:    outRed,
            rawGreen:  outGreen,
            rawBlue:   outBlue
        )
    }
}
