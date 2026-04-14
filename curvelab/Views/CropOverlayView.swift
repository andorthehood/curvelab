import SwiftUI

struct CropOverlayView: View {
    @Binding var cropState: CropState
    let imageSize: CGSize
    let viewSize: CGSize
    var aspectRatio: CGSize? = nil

    @State private var isDragging      = false
    @State private var activeHandle: HandleKind? = nil
    @State private var lastTranslation: CGSize   = .zero

    // MARK: - Coordinate helpers

    private var scale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    }
    private var offsetX: CGFloat { (viewSize.width  - imageSize.width  * scale) / 2 }
    private var offsetY: CGFloat { (viewSize.height - imageSize.height * scale) / 2 }

    /// CIImage pixel coords (origin bottom-left) → SwiftUI view points (origin top-left)
    private func imageToPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offsetX,
                y: viewSize.height - (p.y * scale + offsetY))
    }

    /// Crop rect expressed in SwiftUI view-point coordinates
    private var cropRectInView: CGRect {
        let tl = imageToPoint(CGPoint(x: cropState.rect.minX, y: cropState.rect.maxY))
        let br = imageToPoint(CGPoint(x: cropState.rect.maxX, y: cropState.rect.minY))
        return CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
    }

    // MARK: - Handle kinds

    enum HandleKind: CaseIterable, Hashable {
        case topLeft, topRight, bottomLeft, bottomRight
        case topMid, bottomMid, leftMid, rightMid
    }

    private func handleCenter(for kind: HandleKind, in box: CGRect) -> CGPoint {
        switch kind {
        case .topLeft:     return CGPoint(x: box.minX, y: box.minY)
        case .topRight:    return CGPoint(x: box.maxX, y: box.minY)
        case .bottomLeft:  return CGPoint(x: box.minX, y: box.maxY)
        case .bottomRight: return CGPoint(x: box.maxX, y: box.maxY)
        case .topMid:      return CGPoint(x: box.midX, y: box.minY)
        case .bottomMid:   return CGPoint(x: box.midX, y: box.maxY)
        case .leftMid:     return CGPoint(x: box.minX, y: box.midY)
        case .rightMid:    return CGPoint(x: box.maxX, y: box.midY)
        }
    }

    private let hitRadius: CGFloat = 20

    private func nearestHandle(to point: CGPoint, in box: CGRect) -> HandleKind? {
        let closest = HandleKind.allCases.min {
            dist(handleCenter(for: $0, in: box), point) <
            dist(handleCenter(for: $1, in: box), point)
        }
        guard let closest,
              dist(handleCenter(for: closest, in: box), point) <= hitRadius else { return nil }
        return closest
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func nsCursor(for kind: HandleKind?) -> NSCursor {
        switch kind {
        case .topMid, .bottomMid:        return .resizeUpDown
        case .leftMid, .rightMid:        return .resizeLeftRight
        case .topLeft, .bottomRight:     return .crosshair
        case .topRight, .bottomLeft:     return .crosshair
        case nil:                        return .arrow
        }
    }

    // MARK: - Drag application

    private func applyViewDelta(_ delta: CGSize, for kind: HandleKind) {
        let dx =  delta.width  / scale
        let dy = -delta.height / scale   // flip: down in view = smaller y in image space

        var r = cropState.rect
        let minSize = CropState.minimumSize

        // 1. Apply unconstrained delta
        switch kind {
        // "top" in view = maxY in CIImage: change height only, origin.y fixed
        case .topLeft:
            r.origin.x    += dx;  r.size.width  -= dx   // left edge
            r.size.height += dy                           // top edge (maxY = origin.y + height)
        case .topRight:
            r.size.width  += dx                           // right edge
            r.size.height += dy                           // top edge
        case .topMid:
            r.size.height += dy                           // top edge only

        // "bottom" in view = origin.y in CIImage: change origin.y, compensate height
        case .bottomLeft:
            r.origin.x    += dx;  r.size.width  -= dx   // left edge
            r.origin.y    += dy;  r.size.height -= dy   // bottom edge (origin.y)
        case .bottomRight:
            r.size.width  += dx                           // right edge
            r.origin.y    += dy;  r.size.height -= dy   // bottom edge
        case .bottomMid:
            r.origin.y    += dy;  r.size.height -= dy   // bottom edge only

        // horizontal-only
        case .leftMid:
            r.origin.x    += dx;  r.size.width  -= dx
        case .rightMid:
            r.size.width  += dx
        }

        // 2. Enforce aspect ratio before minSize so anchor geometry stays clean.
        //    The opposite edge is algebraically preserved by the delta above (e.g.
        //    topLeft: maxX = origin.x+w is unchanged), so we can read it from r.
        if let ar = aspectRatio {
            let ratio = ar.width / ar.height
            switch kind {
            case .topLeft, .topRight:
                // bottom edge (origin.y) is the anchor
                r.size.height = r.size.width / ratio
            case .bottomLeft, .bottomRight:
                // top edge (maxY) is the anchor — preserved by origin.y±dy + height∓dy
                let topY = r.maxY
                r.size.height = r.size.width / ratio
                r.origin.y    = topY - r.size.height
            case .leftMid, .rightMid:
                // vertical centre is the anchor (origin.y unchanged, height unchanged)
                let midY = r.midY
                r.size.height = r.size.width / ratio
                r.origin.y    = midY - r.size.height / 2
            case .topMid, .bottomMid:
                // horizontal centre is the anchor (origin.x unchanged, width unchanged)
                let midX = r.midX
                r.size.width  = r.size.height * ratio
                r.origin.x    = midX - r.size.width / 2
            }
        }

        // 3. Enforce minimum size
        if r.size.width  < minSize { r.size.width  = minSize }
        if r.size.height < minSize { r.size.height = minSize }

        cropState = CropState(rect: r, isActive: cropState.isActive)
            .clamped(to: CGRect(origin: .zero, size: imageSize))
    }

    // MARK: - Body

    var body: some View {
        let box = cropRectInView

        ZStack {
            // Visual layer — scrims, border, grid. Never intercepts input.
            Canvas { ctx, size in
                let scrim = Color.black.opacity(0.55)
                ctx.fill(Path(CGRect(x: 0,        y: 0,        width: size.width,              height: box.minY)),              with: .color(scrim))
                ctx.fill(Path(CGRect(x: 0,        y: box.maxY, width: size.width,              height: size.height - box.maxY)), with: .color(scrim))
                ctx.fill(Path(CGRect(x: 0,        y: box.minY, width: box.minX,                height: box.height)),            with: .color(scrim))
                ctx.fill(Path(CGRect(x: box.maxX, y: box.minY, width: size.width - box.maxX,   height: box.height)),            with: .color(scrim))

                ctx.stroke(Path(box), with: .color(.white), lineWidth: 1.5)

                if isDragging {
                    var grid = Path()
                    for i in 1...2 {
                        let x = box.minX + CGFloat(i) * box.width  / 3
                        grid.move(to: CGPoint(x: x, y: box.minY)); grid.addLine(to: CGPoint(x: x, y: box.maxY))
                        let y = box.minY + CGFloat(i) * box.height / 3
                        grid.move(to: CGPoint(x: box.minX, y: y)); grid.addLine(to: CGPoint(x: box.maxX, y: y))
                    }
                    ctx.stroke(grid, with: .color(.white.opacity(0.45)), lineWidth: 0.75)
                }

                // Draw handle dots
                for kind in HandleKind.allCases {
                    let c = handleCenter(for: kind, in: box)
                    let dot = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
                    ctx.fill(Path(dot), with: .color(.white))
                }
            }
            .allowsHitTesting(false)

            // Single transparent interaction layer covering the full overlay
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Latch the handle on first event
                            if activeHandle == nil {
                                activeHandle = nearestHandle(to: value.startLocation, in: box)
                            }
                            guard let handle = activeHandle else { return }
                            let delta = CGSize(
                                width:  value.translation.width  - lastTranslation.width,
                                height: value.translation.height - lastTranslation.height
                            )
                            lastTranslation = value.translation
                            isDragging = true
                            applyViewDelta(delta, for: handle)
                        }
                        .onEnded { _ in
                            activeHandle    = nil
                            lastTranslation = .zero
                            isDragging      = false
                        }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        nsCursor(for: nearestHandle(to: location, in: box)).push()
                    case .ended:
                        NSCursor.pop()
                    }
                }
        }
    }
}
