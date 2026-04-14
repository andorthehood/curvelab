import Foundation

/// Serialisable snapshot of all non-destructive editing decisions.
/// Saved as a JSON sidecar next to the source file (e.g. photo.curvelab).
struct EditingState: Codable {
    var version: Int = 1
    var rotation: Double
    var isNegative: Bool
    var appliedCropRect: CodableRect?
    var inputBlackPoint: Double
    var inputWhitePoint: Double
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

    // MARK: - Codable with backward-compatible defaults for new fields

    enum CodingKeys: String, CodingKey {
        case version, rotation, isNegative, appliedCropRect
        case inputBlackPoint, inputWhitePoint
        case curves
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version          = try c.decodeIfPresent(Int.self,        forKey: .version)          ?? 1
        rotation         = try c.decode(Double.self,              forKey: .rotation)
        isNegative       = try c.decode(Bool.self,                forKey: .isNegative)
        appliedCropRect  = try c.decodeIfPresent(CodableRect.self, forKey: .appliedCropRect)
        inputBlackPoint  = try c.decodeIfPresent(Double.self,     forKey: .inputBlackPoint)  ?? 0.0
        inputWhitePoint  = try c.decodeIfPresent(Double.self,     forKey: .inputWhitePoint)  ?? 1.0
        curves           = try c.decode(CodableCurves.self,       forKey: .curves)
    }

    // MARK: - Convenience init from live model

    init(rotation: Double, isNegative: Bool, appliedCropRect: CGRect?,
         inputBlackPoint: Double, inputWhitePoint: Double, curves: CurveModel) {
        self.rotation = rotation
        self.isNegative = isNegative
        self.appliedCropRect = appliedCropRect.map { CodableRect($0) }
        self.inputBlackPoint = inputBlackPoint
        self.inputWhitePoint = inputWhitePoint
        self.curves = CodableCurves(from: curves)
    }

    // MARK: - Apply to live model

    func apply(to curveModel: CurveModel) {
        curves.apply(to: curveModel)
    }
}

// MARK: - Sidecar URL helper

extension URL {
    var curvelabSidecar: URL {
        deletingPathExtension().appendingPathExtension("curvelab")
    }
}
