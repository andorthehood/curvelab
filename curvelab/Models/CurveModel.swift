import Foundation
import Combine

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
