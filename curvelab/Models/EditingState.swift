import Foundation

/// Serialisable snapshot of all non-destructive editing decisions.
/// Saved as a JSON sidecar next to the source file (e.g. photo.curvelab).
struct EditingState: Codable {
    var version: Int = 1
    var rotation: Double
    var isNegative: Bool
    var appliedCropRect: CodableRect?
    var curves: CodableCurves

    // MARK: - Nested types

    struct CodableRect: Codable {
        var x, y, width, height: Double

        init(_ r: CGRect) {
            x = r.origin.x; y = r.origin.y
            width = r.size.width; height = r.size.height
        }

        var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    struct CodableCurves: Codable {
        var rgb, red, green, blue: [Point]
    }

    struct Point: Codable {
        var x, y: Double
    }

    // MARK: - Convenience init from live model

    init(rotation: Double, isNegative: Bool, appliedCropRect: CGRect?, curves: CurveModel) {
        self.rotation = rotation
        self.isNegative = isNegative
        self.appliedCropRect = appliedCropRect.map { CodableRect($0) }
        self.curves = CodableCurves(
            rgb:   curves.rgb.points.map   { Point(x: $0.x, y: $0.y) },
            red:   curves.red.points.map   { Point(x: $0.x, y: $0.y) },
            green: curves.green.points.map { Point(x: $0.x, y: $0.y) },
            blue:  curves.blue.points.map  { Point(x: $0.x, y: $0.y) }
        )
    }

    // MARK: - Apply to live model

    func apply(to curveModel: CurveModel) {
        curveModel.rgb   = ChannelCurve(points: curves.rgb.map   { CurveControlPoint(x: $0.x, y: $0.y) })
        curveModel.red   = ChannelCurve(points: curves.red.map   { CurveControlPoint(x: $0.x, y: $0.y) })
        curveModel.green = ChannelCurve(points: curves.green.map { CurveControlPoint(x: $0.x, y: $0.y) })
        curveModel.blue  = ChannelCurve(points: curves.blue.map  { CurveControlPoint(x: $0.x, y: $0.y) })
    }
}

// MARK: - Sidecar URL helper

extension URL {
    var curvelabSidecar: URL {
        deletingPathExtension().appendingPathExtension("curvelab")
    }
}
