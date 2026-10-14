import Foundation

/// Picks the next token from a step's log probabilities.
public protocol TokenSampler {
    mutating func sample(from logProbabilities: [Float]) -> Int
}

/// CTranslate2 `BestSampler` (temperature 0): the most likely token, the lowest id on ties.
public struct GreedySampler: TokenSampler {
    public init() {}

    public func sample(from logProbabilities: [Float]) -> Int {
        var bestToken = 0
        for token in logProbabilities.indices where logProbabilities[token] > logProbabilities[bestToken] {
            bestToken = token
        }
        return bestToken
    }
}

/// CTranslate2 `RandomSampler` with `sampling_topk=0` (whole vocabulary):
/// log probabilities divided by the temperature, softmax, one multinomial draw.
/// The recorded score stays the untempered log probability.
public struct TemperatureSampler<Generator: RandomNumberGenerator>: TokenSampler {
    public let temperature: Float
    private var generator: Generator

    public init(temperature: Float, generator: Generator) {
        precondition(temperature > 0, "use GreedySampler for temperature 0")
        self.temperature = temperature
        self.generator = generator
    }

    public mutating func sample(from logProbabilities: [Float]) -> Int {
        let scaled = logProbabilities.map { $0 / temperature }
        let probabilities = LogSoftmax.apply(scaled).map { exp($0) }
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
