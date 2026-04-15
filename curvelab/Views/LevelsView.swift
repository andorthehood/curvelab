import SwiftUI

/// Compact input-levels control: a histogram with two draggable handles for
/// black point (left) and white point (right).  The handles operate in the
/// 0…1 normalised domain matching the float32 cache values.
///
/// A range strip sits above the histogram showing the [blackPoint, whitePoint]
/// span as a segment; dragging it shifts both handles together.
///
/// An additional downward-pointing handle at the top edge mirrors the black-point
/// position but also adjusts all curves to preserve output values when dragged.
/// Supply `onLinkedBlackPointChanged` to opt in to that behaviour.
struct LevelsView: View {
    @Binding var blackPoint: Double
    @Binding var whitePoint: Double
    var histogram: HistogramData?
    /// Called with the new black-point value when the linked (top) handle is dragged.
    var onLinkedBlackPointChanged: ((Double) -> Void)? = nil
    /// Hard cap for the linked handle — dragging past this would crush the curve's leftmost point.
    var linkedBlackPointMax: Double = 1.0
    /// Called once at the start of any drag so the caller can capture an undo snapshot.
    var onDragBegan: (() -> Void)? = nil

    /// Minimum gap between handles (in normalised units)
    private let minimumSpan: Double = 0.01
    private let handleWidth: CGFloat = 10
    private let viewHeight: CGFloat = 50
    private let stripHeight: CGFloat = 14
    private let hitSlop: CGFloat = 18

    // Which handle is being dragged?
    @State private var dragging: Handle? = nil
    // Captured start values for range strip drag
    @State private var rangeStartBP: Double? = nil
    @State private var rangeStartWP: Double? = nil

    private enum Handle { case black, white, blackLinked }

    var body: some View {
        VStack(spacing: 0) {
            // Range strip — drag to shift black and white point together
            GeometryReader { stripGeo in
                let w = stripGeo.size.width
                let bpX = CGFloat(blackPoint) * w
                let wpX = CGFloat(whitePoint) * w

                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                                 with: .color(Color(white: 0.15)))
                        let segRect = CGRect(x: bpX, y: 2,
                                             width: max(0, wpX - bpX),
                                             height: size.height - 4)
                        ctx.fill(Path(segRect), with: .color(Color(white: 0.55).opacity(0.55)))
                        ctx.stroke(Path(CGRect(origin: .zero, size: size)),
                                   with: .color(Color(white: 0.3)), lineWidth: 1)
                    }
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in onRangeDrag(value: value, width: w) }
                                .onEnded   { _ in rangeStartBP = nil; rangeStartWP = nil }
                        )
                }
            }
            .frame(height: stripHeight)

            // Histogram + handles
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        drawHistogram(ctx: ctx, size: size)
                        drawHandles(ctx: ctx, size: size)
                    }
                    .frame(height: viewHeight)

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in onDrag(value: value, width: w) }
                                .onEnded   { _ in dragging = nil }
                        )
                }
            }
            .frame(height: viewHeight)
        }
    }

    // MARK: - Drawing

    private func drawHistogram(ctx: GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        // Background
        ctx.fill(Path(rect), with: .color(Color(white: 0.15)))

        guard let histogram else {
            ctx.stroke(Path(rect), with: .color(Color(white: 0.3)), lineWidth: 1)
            return
        }

        // Draw all three channels faintly + luminance outline
        let channels: [([Float], Color)] = [
            (histogram.red,   .red),
            (histogram.green, .green),
            (histogram.blue,  Color(red: 0.3, green: 0.5, blue: 1.0))
        ]
        for (bins, color) in channels {
            let path = histogramPath(bins: bins, in: rect)
            ctx.fill(path, with: .color(color.opacity(0.2)))
        }
        let lumPath = histogramPath(bins: histogram.luminance, in: rect)
        ctx.stroke(lumPath, with: .color(Color(white: 0.5)), lineWidth: 1)

        // Shade the clipped regions (outside the [blackPoint, whitePoint] range)
        let bpX = CGFloat(blackPoint) * rect.width
        let wpX = CGFloat(whitePoint) * rect.width
        let shadingColor = Color.black.opacity(0.45)

        if bpX > 0 {
            let leftRect = CGRect(x: rect.minX, y: rect.minY, width: bpX, height: rect.height)
            ctx.fill(Path(leftRect), with: .color(shadingColor))
        }
        if wpX < rect.width {
            let rightRect = CGRect(x: wpX, y: rect.minY,
                                   width: rect.width - wpX, height: rect.height)
            ctx.fill(Path(rightRect), with: .color(shadingColor))
        }

        // Border
        ctx.stroke(Path(rect), with: .color(Color(white: 0.3)), lineWidth: 1)
    }

    private func drawHandles(ctx: GraphicsContext, size: CGSize) {
        let h = size.height
        let bpX = CGFloat(blackPoint) * size.width
        let wpX = CGFloat(whitePoint) * size.width

        // Linked black-point handle — downward triangle at top
        if onLinkedBlackPointChanged != nil {
            drawTopHandle(ctx: ctx, x: bpX)
        }
        // Black-point handle — upward triangle at bottom, dark fill
        drawBottomHandle(ctx: ctx, x: bpX, height: h, isBlack: true)
        // White-point handle — upward triangle at bottom, light fill
        drawBottomHandle(ctx: ctx, x: wpX, height: h, isBlack: false)
    }

    private func drawTopHandle(ctx: GraphicsContext, x: CGFloat) {
        let half = handleWidth / 2
        // Vertical tick — top quarter only, so it doesn't clash with the bottom handle's tick
        var line = Path()
        line.move(to: CGPoint(x: x, y: 1))
        line.addLine(to: CGPoint(x: x, y: viewHeight * 0.35))
        ctx.stroke(line, with: .color(Color(white: 0.5)), lineWidth: 1.5)

        // Downward-pointing triangle at top
        var tri = Path()
        tri.move(to: CGPoint(x: x - half, y: 1))
        tri.addLine(to: CGPoint(x: x + half, y: 1))
        tri.addLine(to: CGPoint(x: x, y: 1 + half * 1.4))
        tri.closeSubpath()
        ctx.fill(tri, with: .color(Color(white: 0.35)))
        ctx.stroke(tri, with: .color(Color(white: 0.65)), lineWidth: 1)
    }

    private func drawBottomHandle(ctx: GraphicsContext, x: CGFloat, height: CGFloat, isBlack: Bool) {
        let half = handleWidth / 2
        // Vertical tick line
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: height))
        ctx.stroke(line, with: .color(isBlack ? Color(white: 0.25) : Color(white: 0.9)), lineWidth: 1.5)

        // Triangle at bottom pointing upward
        let ty = height - 1
        var tri = Path()
        tri.move(to: CGPoint(x: x - half, y: ty))
        tri.addLine(to: CGPoint(x: x + half, y: ty))
        tri.addLine(to: CGPoint(x: x, y: ty - half * 1.4))
        tri.closeSubpath()

        let fill: Color = isBlack ? Color(white: 0.15) : Color(white: 0.92)
        let stroke: Color = isBlack ? Color(white: 0.6) : Color(white: 1.0)
        ctx.fill(tri, with: .color(fill))
        ctx.stroke(tri, with: .color(stroke), lineWidth: 1)
    }

    // MARK: - Histogram path helper

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

    // MARK: - Gestures

    private func onRangeDrag(value: DragGesture.Value, width: CGFloat) {
        guard width > 0 else { return }
        if rangeStartBP == nil {
            onDragBegan?()
            rangeStartBP = blackPoint
            rangeStartWP = whitePoint
        }
        guard let startBP = rangeStartBP, let startWP = rangeStartWP else { return }
        let delta = Double((value.location.x - value.startLocation.x) / width)
        let span  = startWP - startBP
        let newBP = max(0, min(1 - span, startBP + delta))
        blackPoint = newBP
        whitePoint = newBP + span
    }

    private func onDrag(value: DragGesture.Value, width: CGFloat) {
        guard width > 0 else { return }

        if dragging == nil {
            let bpX    = CGFloat(blackPoint) * width
            let wpX    = CGFloat(whitePoint) * width
            let startX = value.startLocation.x
            let startY = value.startLocation.y

            // Top zone: linked black-point handle (top ~35% of height)
            if onLinkedBlackPointChanged != nil,
               startY < viewHeight * 0.35,
               abs(startX - bpX) < hitSlop {
                dragging = .blackLinked
            }
            // Bottom zone: regular black / white handles
            else if startY > viewHeight * 0.5 {
                let distBlack = abs(startX - bpX)
                let distWhite = abs(startX - wpX)
                if distBlack < hitSlop || distWhite < hitSlop {
                    dragging = distBlack <= distWhite ? .black : .white
                }
            }
            guard dragging != nil else { return }
            onDragBegan?()
        }

        let normalised = max(0, min(1, Double(value.location.x / width)))

        switch dragging {
        case .black:
            blackPoint = min(normalised, whitePoint - minimumSpan)
        case .white:
            whitePoint = max(normalised, blackPoint + minimumSpan)
        case .blackLinked:
            let clamped = min(normalised, linkedBlackPointMax, whitePoint - minimumSpan)
            onLinkedBlackPointChanged?(max(0, clamped))
        case nil:
            break
        }
    }
}
