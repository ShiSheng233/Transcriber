import Accelerate
import Foundation

/// Picks the next token from a step's log probabilities.
public protocol TokenSampler {
    func sample(from logProbabilities: [Float], using generator: inout some RandomNumberGenerator) -> Int
}

/// CTranslate2 `BestSampler` (temperature 0): the most likely token, the lowest id on ties.
public struct GreedySampler: TokenSampler {
    public init() {}

    public func sample(from logProbabilities: [Float], using generator: inout some RandomNumberGenerator) -> Int {
        // vDSP reports the first index of the maximum.
        Int(vDSP.indexOfMaximum(logProbabilities).0)
    }
}

/// CTranslate2 `RandomSampler` with `sampling_topk=0` (whole vocabulary):
/// log probabilities divided by the temperature, softmax, one multinomial draw.
/// The recorded score stays the untempered log probability.
public struct TemperatureSampler: TokenSampler {
    public let temperature: Float

    public init(temperature: Float) {
        precondition(temperature > 0, "use GreedySampler for temperature 0")
        self.temperature = temperature
    }

    public func sample(from logProbabilities: [Float], using generator: inout some RandomNumberGenerator) -> Int {
        let probabilities = vForce.exp(LogSoftmax.apply(vDSP.divide(logProbabilities, temperature)))
        var remaining = Float.random(in: 0..<1, using: &generator)
        for (token, probability) in probabilities.enumerated() where probability > 0 {
            remaining -= probability
            if remaining < 0 {
                return token
            }
        }
        // Rounding left a little probability mass unassigned: take the last possible token.
        return probabilities.lastIndex(where: { $0 > 0 }) ?? 0
    }
}
