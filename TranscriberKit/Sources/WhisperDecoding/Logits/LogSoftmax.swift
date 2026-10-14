import Foundation

enum LogSoftmax {
    static func apply(_ logits: [Float]) -> [Float] {
        let normalizer = logSumExp(logits[...])
        return logits.map { $0 - normalizer }
    }

    /// Stable log(sum(exp(x))); -infinity when every value is -infinity.
    static func logSumExp(_ values: ArraySlice<Float>) -> Float {
        guard let maximum = values.max(), maximum > -.infinity else {
            return -.infinity
        }
        let sum = values.reduce(Float(0)) { $0 + exp($1 - maximum) }
        return maximum + log(sum)
    }
}
