import Foundation

/// Natural cubic spline interpolation through sorted control points.
struct CubicSpline {
    private let xs: [Double]
    private let ys: [Double]
    private let ms: [Double] // second derivatives

    init(points: [(x: Double, y: Double)]) {
        let sorted = points.sorted { $0.x < $1.x }
        self.xs = sorted.map(\.x)
        self.ys = sorted.map(\.y)

        let n = sorted.count
        guard n >= 2 else {
            self.ms = Array(repeating: 0, count: n)
            return
        }

        // Compute intervals and slopes
        var h = [Double](repeating: 0, count: n - 1)
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            h[i] = xs[i + 1] - xs[i]
            delta[i] = (ys[i + 1] - ys[i]) / h[i]
        }

        if n == 2 {
            self.ms = [0, 0]
            return
        }

        // Tridiagonal system (Thomas algorithm) for natural spline (M_0 = M_{n-1} = 0)
        let interior = n - 2
        var a = [Double](repeating: 0, count: interior) // sub-diagonal
        var b = [Double](repeating: 0, count: interior) // diagonal
        var c = [Double](repeating: 0, count: interior) // super-diagonal
        var d = [Double](repeating: 0, count: interior) // RHS

        for i in 0..<interior {
            a[i] = h[i]
            b[i] = 2 * (h[i] + h[i + 1])
            c[i] = h[i + 1]
            d[i] = 6 * (delta[i + 1] - delta[i])
        }

        // Forward elimination
        for i in 1..<interior {
            let w = a[i] / b[i - 1]
            b[i] -= w * c[i - 1]
            d[i] -= w * d[i - 1]
        }

        // Back substitution
        var mInterior = [Double](repeating: 0, count: interior)
        mInterior[interior - 1] = d[interior - 1] / b[interior - 1]
        for i in stride(from: interior - 2, through: 0, by: -1) {
            mInterior[i] = (d[i] - c[i] * mInterior[i + 1]) / b[i]
        }

        // Natural boundary: M_0 = 0, M_{n-1} = 0
        var result = [Double](repeating: 0, count: n)
        for i in 0..<interior {
            result[i + 1] = mInterior[i]
        }
        self.ms = result
    }

    func evaluate(at t: Double) -> Double {
        let n = xs.count
        guard n >= 2 else { return ys.first ?? t }

        // Clamp to range
        if t <= xs[0] { return ys[0] }
        if t >= xs[n - 1] { return ys[n - 1] }

        // Binary search for interval
        var lo = 0, hi = n - 2
        while lo < hi {
            let mid = (lo + hi) / 2
            if xs[mid + 1] < t {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let i = lo

        let hi_val = xs[i + 1] - t
        let lo_val = t - xs[i]
        let h = xs[i + 1] - xs[i]

        let value = (ms[i] * hi_val * hi_val * hi_val + ms[i + 1] * lo_val * lo_val * lo_val) / (6 * h)
            + (ys[i] / h - ms[i] * h / 6) * hi_val
            + (ys[i + 1] / h - ms[i + 1] * h / 6) * lo_val

        return min(1, max(0, value))
    }

    func generateLUT(size: Int = 256) -> [Float] {
        (0..<size).map { i in
            Float(evaluate(at: Double(i) / Double(size - 1)))
        }
    }
}
