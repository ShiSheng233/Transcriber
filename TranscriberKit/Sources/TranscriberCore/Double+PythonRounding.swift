import Foundation

extension Double {
    /// Python's `round(x, places)`: the exact binary value rounded half to even
    /// at `places` decimals, so `round(2.675, 2) == 2.67` (2.675 is stored as
    /// 2.67499999...). Scaling by 10^places can itself round, so the exact
    /// remainder from a fused multiply-add settles values that land on a half.
    public func pythonRounded(toPlaces places: Int) -> Double {
        precondition((0...15).contains(places), "decimal places out of range")
        let scale = pow(10, Double(places))
        let scaled = self * scale
        let scalingError = fma(self, scale, -scaled)  // self * scale - scaled, exactly
        var rounded = scaled.rounded(.toNearestOrEven)
        let landsOnHalf = abs(scaled - scaled.rounded(.towardZero)) == 0.5
        if landsOnHalf && scalingError != 0 {
            rounded = scalingError > 0 ? scaled.rounded(.up) : scaled.rounded(.down)
        }
        return rounded / scale
    }
}
