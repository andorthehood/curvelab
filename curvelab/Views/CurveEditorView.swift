import SwiftUI

struct CurveEditorView: View {
    @ObservedObject var curves: CurveModel
    var histogram: HistogramData?
    var blackPoint: Double = 0
    var whitePoint: Double = 1
    @State private var draggingPointID: UUID?

    private let handleRadius: CGFloat = 6
    private let hitRadius: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let origin = CGPoint(
                x: (geo.size.width - size) / 2,
                y: (geo.size.height - size) / 2
            )

            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    let rect = CGRect(origin: origin, size: CGSize(width: size, height: size))
                    drawBackground(context: context, rect: rect)
                    drawHistogram(context: context, rect: rect)
                    drawInactiveCurves(context: context, rect: rect)
                    drawActiveCurve(context: context, rect: rect)
                    drawHandles(context: context, rect: rect)
                }
                .onTapGesture(count: 2) { location in
                    onDoubleClick(location: location, size: size, origin: origin)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            onDrag(value: value, size: size, origin: origin)
                        }
                        .onEnded { _ in
                            draggingPointID = nil
                        }
                )
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Drawing

    private func drawBackground(context: GraphicsContext, rect: CGRect) {
        // Background
        context.fill(Path(rect), with: .color(Color(white: 0.15)))

        // Grid lines at 25% intervals
        let gridColor = Color(white: 0.25)
        for i in 1...3 {
            let frac = CGFloat(i) / 4.0
            let x = rect.minX + frac * rect.width
            let y = rect.minY + frac * rect.height

            var vPath = Path()
            vPath.move(to: CGPoint(x: x, y: rect.minY))
            vPath.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(vPath, with: .color(gridColor), lineWidth: 0.5)

            var hPath = Path()
            hPath.move(to: CGPoint(x: rect.minX, y: y))
            hPath.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(hPath, with: .color(gridColor), lineWidth: 0.5)
        }

        // Identity diagonal (dashed)
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        diagonal.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        context.stroke(diagonal, with: .color(Color(white: 0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // Border
        context.stroke(Path(rect), with: .color(Color(white: 0.3)), lineWidth: 1)
    }

    private func drawHistogram(context: GraphicsContext, rect: CGRect) {
        guard let histogram else { return }

        let channel = curves.activeChannel
        let bins: [Float]
        let color: Color

        switch channel {
        case .rgb:
            bins = histogram.luminance
            color = Color(white: 0.35)
        case .red:
            bins = histogram.red
            color = Color.red.opacity(0.25)
        case .green:
            bins = histogram.green
            color = Color.green.opacity(0.25)
        case .blue:
            bins = histogram.blue
            color = Color(red: 0.3, green: 0.5, blue: 1.0).opacity(0.25)
        }

        let binCount = bins.count
        let lo = blackPoint
        let hi = whitePoint
        let levelsRange = hi - lo

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))

        for i in 0..<binCount {
            // Raw normalised position 0…1 for this bin
            let raw = Double(i) / Double(binCount - 1)
            // Remap through levels range so the visible window stretches to fill full width
            let displayT: Double = levelsRange > 0
                ? max(0, min(1, (raw - lo) / levelsRange))
                : Double(i) / Double(binCount - 1)
            let x = rect.minX + CGFloat(displayT) * rect.width
            let h = CGFloat(bins[i]) * rect.height
            path.addLine(to: CGPoint(x: x, y: rect.maxY - h))
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()

        context.fill(path, with: .color(color))
    }

    private func drawInactiveCurves(context: GraphicsContext, rect: CGRect) {
        let channels: [(CurveChannel, ChannelCurve)] = [
            (.rgb, curves.rgb),
            (.red, curves.red),
            (.green, curves.green),
            (.blue, curves.blue)
        ]

        for (channel, curve) in channels where channel != curves.activeChannel {
            let path = curvePath(for: curve, in: rect)
            let color = channelColor(channel).opacity(0.2)
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }

    private func drawActiveCurve(context: GraphicsContext, rect: CGRect) {
        let curve = curves.activeCurve
        let path = curvePath(for: curve, in: rect)
        let color = channelColor(curves.activeChannel)
        context.stroke(path, with: .color(color), lineWidth: 2)
    }

    private func drawHandles(context: GraphicsContext, rect: CGRect) {
        let curve = curves.activeCurve
        let color = channelColor(curves.activeChannel)

        for point in curve.sortedPoints {
            let center = pointToScreen(point, in: rect)
            let handleRect = CGRect(
                x: center.x - handleRadius,
                y: center.y - handleRadius,
                width: handleRadius * 2,
                height: handleRadius * 2
            )
            context.fill(Path(ellipseIn: handleRect), with: .color(.white))
            context.stroke(Path(ellipseIn: handleRect), with: .color(color), lineWidth: 2)
        }
    }

    private func curvePath(for curve: ChannelCurve, in rect: CGRect) -> Path {
        let spline = curve.spline()
        let steps = Int(rect.width)
        var path = Path()

        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let y = spline.evaluate(at: t)
            let screenX = rect.minX + CGFloat(t) * rect.width
            let screenY = rect.maxY - CGFloat(y) * rect.height

            if i == 0 {
                path.move(to: CGPoint(x: screenX, y: screenY))
            } else {
                path.addLine(to: CGPoint(x: screenX, y: screenY))
            }
        }
        return path
    }

    // MARK: - Coordinate conversion

    private func pointToScreen(_ point: CurveControlPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + CGFloat(point.x) * rect.width,
            y: rect.maxY - CGFloat(point.y) * rect.height
        )
    }

    private func screenToNormalized(_ location: CGPoint, size: CGFloat, origin: CGPoint) -> (x: Double, y: Double) {
        let x = Double((location.x - origin.x) / size)
        let y = Double(1 - (location.y - origin.y) / size)
        return (min(1, max(0, x)), min(1, max(0, y)))
    }

    // MARK: - Gestures

    private func onDrag(value: DragGesture.Value, size: CGFloat, origin: CGPoint) {
        let rect = CGRect(origin: origin, size: CGSize(width: size, height: size))
        let norm = screenToNormalized(value.location, size: size, origin: origin)

        if draggingPointID == nil {
            // Find nearest existing point within hit radius
            let curve = curves.activeCurve
            var bestID: UUID?
            var bestDist: CGFloat = .infinity

            for point in curve.sortedPoints {
                let screenPos = pointToScreen(point, in: rect)
                let dist = hypot(value.startLocation.x - screenPos.x, value.startLocation.y - screenPos.y)
                if dist < hitRadius && dist < bestDist {
                    bestDist = dist
                    bestID = point.id
                }
            }

            if let id = bestID {
                draggingPointID = id
            } else {
                // No existing point nearby — add a new one on the curve and start dragging it
                let startNorm = screenToNormalized(value.startLocation, size: size, origin: origin)
                if startNorm.x > 0.01 && startNorm.x < 0.99 {
                    curves.activeCurve.addPoint(at: startNorm.x)
                    // Find the newly added point (closest to startNorm.x)
                    let sorted = curves.activeCurve.sortedPoints
                    if let newPoint = sorted.min(by: { abs($0.x - startNorm.x) < abs($1.x - startNorm.x) }) {
                        draggingPointID = newPoint.id
                    }
                }
            }
        }

        if let id = draggingPointID {
            curves.activeCurve.movePoint(id: id, to: norm.x, y: norm.y)
        }
    }

    private func onDoubleClick(location: CGPoint, size: CGFloat, origin: CGPoint) {
        let rect = CGRect(origin: origin, size: CGSize(width: size, height: size))
        if let id = nearestPoint(to: location, in: rect) {
            curves.activeCurve.removePoint(id: id)
        } else {
            let norm = screenToNormalized(location, size: size, origin: origin)
            if norm.x > 0.02 && norm.x < 0.98 {
                curves.activeCurve.addPoint(at: norm.x)
            }
        }
    }

    private func nearestPoint(to location: CGPoint, in rect: CGRect) -> UUID? {
        var bestID: UUID?
        var bestDist: CGFloat = hitRadius
        for point in curves.activeCurve.sortedPoints {
            let screenPos = pointToScreen(point, in: rect)
            let dist = hypot(location.x - screenPos.x, location.y - screenPos.y)
            if dist < bestDist {
                bestDist = dist
                bestID = point.id
            }
        }
        return bestID
    }

    // MARK: - Colors

    private func channelColor(_ channel: CurveChannel) -> Color {
        switch channel {
        case .rgb: .white
        case .red: .red
        case .green: .green
        case .blue: Color(red: 0.3, green: 0.5, blue: 1.0)
        }
    }
}

