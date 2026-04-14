import Foundation

struct Preset: Codable, Identifiable {
    let id: UUID
    var isNegative: Bool
    var inputBlackPoint: Double
    var inputWhitePoint: Double
    var curves: CodableCurves
}
