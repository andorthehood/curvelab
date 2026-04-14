import Foundation
import Combine

// MARK: - Shared serialisable curve types

struct CurvePoint: Codable {
    var x, y: Double
}

struct CodableCurves: Codable {
    var rgb, red, green, blue: [CurvePoint]
}

extension CodableCurves {
    var rgbCurve:   ChannelCurve { ChannelCurve(points: rgb.map   { CurveControlPoint(x: $0.x, y: $0.y) }) }
    var redCurve:   ChannelCurve { ChannelCurve(points: red.map   { CurveControlPoint(x: $0.x, y: $0.y) }) }
    var greenCurve: ChannelCurve { ChannelCurve(points: green.map { CurveControlPoint(x: $0.x, y: $0.y) }) }
    var blueCurve:  ChannelCurve { ChannelCurve(points: blue.map  { CurveControlPoint(x: $0.x, y: $0.y) }) }

    func apply(to model: CurveModel) {
        model.rgb   = rgbCurve
        model.red   = redCurve
        model.green = greenCurve
        model.blue  = blueCurve
    }

    init(from model: CurveModel) {
        rgb   = model.rgb.points.map   { CurvePoint(x: $0.x, y: $0.y) }
        red   = model.red.points.map   { CurvePoint(x: $0.x, y: $0.y) }
        green = model.green.points.map { CurvePoint(x: $0.x, y: $0.y) }
        blue  = model.blue.points.map  { CurvePoint(x: $0.x, y: $0.y) }
    }
}

// MARK: - Control point

struct CurveControlPoint: Identifiable, Equatable {
    let id: UUID
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.id = UUID()
        self.x = x
        self.y = y
    }
}

struct ChannelCurve: Equatable {
    var points: [CurveControlPoint]

    static var identity: ChannelCurve {
        ChannelCurve(points: [
            CurveControlPoint(x: 0, y: 0),
            CurveControlPoint(x: 1, y: 1)
        ])
    }

    var sortedPoints: [CurveControlPoint] {
        points.sorted { $0.x < $1.x }
    }

    func spline() -> CubicSpline {
        CubicSpline(points: sortedPoints.map { ($0.x, $0.y) })
    }

    func evaluate(at x: Double) -> Double {
        spline().evaluate(at: x)
    }

    mutating func addPoint(at x: Double) {
        guard points.count < 16 else { return }
        let y = evaluate(at: x)
        points.append(CurveControlPoint(x: x, y: y))
        points.sort { $0.x < $1.x }
    }

    mutating func removePoint(id: UUID) {
        guard let index = points.firstIndex(where: { $0.id == id }) else { return }
        let point = points[index]
        // Don't remove endpoints
        if point.x == 0 || point.x == 1 { return }
        // Keep at least 2 points
        if points.count <= 2 { return }
        points.remove(at: index)
    }

    /// Translates all control points horizontally by `delta` (normalised units),
    /// clamping each to [0, 1].  All points move together so relative order and
    /// spacing are preserved — no neighbour-clamping side effects.
    mutating func shiftAllX(by delta: Double) {
        for i in points.indices {
            points[i].x = max(0, min(1, points[i].x + delta))
        }
    }

    /// Remaps all control points for a black-point shift of `x0`.
    /// `x_new = (x - x0) / (1 - x0)`
    /// Positive x0: stretches points left (absorb / linked-drag rightward).
    /// Negative x0: stretches points right (linked-drag leftward / undo).
    mutating func stretchFromBlackPoint(_ x0: Double) {
        guard x0 != 0 else { return }
        let range = 1.0 - x0
        guard abs(range) > 1e-10 else { return }
        for i in points.indices {
            points[i].x = max(0, min(1, (points[i].x - x0) / range))
        }
    }

    mutating func movePoint(id: UUID, to newX: Double, y newY: Double) {
        guard let index = points.firstIndex(where: { $0.id == id }) else { return }
        let sorted = sortedPoints
        guard let sortedIndex = sorted.firstIndex(where: { $0.id == id }) else { return }

        let isFirst = sortedIndex == 0
        let isLast = sortedIndex == sorted.count - 1

        var clampedX: Double
        if isFirst {
            // First point: can move x from 0 up to just before the next point
            let maxX = sorted.count > 1 ? sorted[1].x - 0.01 : 1.0
            clampedX = min(maxX, max(0, newX))
        } else if isLast {
            // Last point: can move x from just after the previous point up to 1
            let minX = sorted[sortedIndex - 1].x + 0.01
            clampedX = min(1, max(minX, newX))
        } else {
            let minX = sorted[sortedIndex - 1].x + 0.01
            let maxX = sorted[sortedIndex + 1].x - 0.01
            clampedX = min(maxX, max(minX, newX))
        }

        points[index].x = clampedX
        points[index].y = min(1, max(0, newY))
    }
}

enum CurveChannel: String, CaseIterable, Identifiable {
    case rgb, red, green, blue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rgb: "RGB"
        case .red: "R"
        case .green: "G"
        case .blue: "B"
        }
    }
}

class CurveModel: ObservableObject {
    @Published var rgb = ChannelCurve.identity
    @Published var red = ChannelCurve.identity
    @Published var green = ChannelCurve.identity
    @Published var blue = ChannelCurve.identity
    @Published var activeChannel: CurveChannel = .rgb

    var activeCurve: ChannelCurve {
        get {
            switch activeChannel {
            case .rgb: rgb
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch activeChannel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    func reset() {
        rgb = .identity
        red = .identity
        green = .identity
        blue = .identity
    }
}
