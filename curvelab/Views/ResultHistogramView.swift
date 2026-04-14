import SwiftUI

struct ResultHistogramView: View {
    let histogram: HistogramData?
    let activeChannel: CurveChannel

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(Color(white: 0.15)))

            guard let histogram else { return }

            // Draw all three channels faintly, active channel on top
            let channels: [(CurveChannel, [Float], Color)] = [
                (.red, histogram.red, .red),
                (.green, histogram.green, .green),
                (.blue, histogram.blue, Color(red: 0.3, green: 0.5, blue: 1.0))
            ]

            if activeChannel == .rgb {
                // Show all three overlaid
                for (_, bins, color) in channels {
                    let path = histogramPath(bins: bins, in: rect)
                    context.fill(path, with: .color(color.opacity(0.3)))
                }
                // Luminance outline
                let lumPath = histogramPath(bins: histogram.luminance, in: rect)
                context.stroke(lumPath, with: .color(Color(white: 0.6)), lineWidth: 1)
            } else {
                // Show inactive channels faintly
                for (channel, bins, color) in channels where channel != activeChannel {
                    let path = histogramPath(bins: bins, in: rect)
                    context.fill(path, with: .color(color.opacity(0.1)))
                }
                // Active channel
                let activeBins: [Float]
                let activeColor: Color
                switch activeChannel {
                case .red:
                    activeBins = histogram.red
                    activeColor = .red
                case .green:
                    activeBins = histogram.green
                    activeColor = .green
                case .blue:
                    activeBins = histogram.blue
                    activeColor = Color(red: 0.3, green: 0.5, blue: 1.0)
                case .rgb:
                    activeBins = histogram.luminance
                    activeColor = .white
                }
                let path = histogramPath(bins: activeBins, in: rect)
                context.fill(path, with: .color(activeColor.opacity(0.35)))
                context.stroke(path, with: .color(activeColor.opacity(0.7)), lineWidth: 1)
            }

            // Border
            context.stroke(Path(rect), with: .color(Color(white: 0.3)), lineWidth: 1)
        }
        .frame(height: 60)
    }

    private func histogramPath(bins: [Float], in rect: CGRect) -> Path {
        let binCount = bins.count
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for i in 0..<binCount {
            let t = CGFloat(i) / CGFloat(binCount - 1)
            let x = rect.minX + t * rect.width
            let h = CGFloat(bins[i]) * rect.height
            path.addLine(to: CGPoint(x: x, y: rect.maxY - h))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
