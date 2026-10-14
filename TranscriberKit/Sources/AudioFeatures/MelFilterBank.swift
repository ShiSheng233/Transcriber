import Foundation

/// Triangular mel filters with Slaney mel scale and Slaney area normalization,
/// matching Hugging Face `mel_filter_bank(norm="slaney", mel_scale="slaney")`
/// (and librosa's defaults, which OpenAI's mel_filters.npz was made with).
enum MelFilterBank {
    /// Returns a `frequencyBinCount x melBandCount` matrix, row major.
    static func make(
        melBandCount: Int,
        frequencyBinCount: Int,
        sampleRate: Int,
        minimumFrequency: Double = 0,
        maximumFrequency: Double
    ) -> [Double] {
        let lowestMel = SlaneyMelScale.mel(fromHertz: minimumFrequency)
        let highestMel = SlaneyMelScale.mel(fromHertz: maximumFrequency)
        // melBandCount triangles need melBandCount + 2 edge frequencies.
        let edgeFrequencies = linearlySpaced(from: lowestMel, to: highestMel, count: melBandCount + 2)
            .map(SlaneyMelScale.hertz(fromMel:))
        let binFrequencies = linearlySpaced(from: 0, to: Double(sampleRate / 2), count: frequencyBinCount)

        var filters = [Double](repeating: 0, count: frequencyBinCount * melBandCount)
        for band in 0..<melBandCount {
            let lower = edgeFrequencies[band]
            let center = edgeFrequencies[band + 1]
            let upper = edgeFrequencies[band + 2]
            let areaNormalization = 2 / (upper - lower)
            for bin in 0..<frequencyBinCount {
                let frequency = binFrequencies[bin]
                let risingSlope = (frequency - lower) / (center - lower)
                let fallingSlope = (upper - frequency) / (upper - center)
                let weight = max(0, min(risingSlope, fallingSlope))
                filters[bin * melBandCount + band] = weight * areaNormalization
            }
        }
        return filters
    }

    private static func linearlySpaced(from start: Double, to end: Double, count: Int) -> [Double] {
        let step = (end - start) / Double(count - 1)
        return (0..<count).map { start + Double($0) * step }
    }
}

/// Slaney's mel scale: linear below 1 kHz, logarithmic above.
enum SlaneyMelScale {
    private static let linearHertzPerMel = 200.0 / 3.0
    private static let logRegionStartHertz = 1_000.0
    private static let logRegionStartMel = logRegionStartHertz / linearHertzPerMel
    private static let melsPerLogStep = 27.0 / log(6.4)

    static func mel(fromHertz hertz: Double) -> Double {
        guard hertz >= logRegionStartHertz else {
            return hertz / linearHertzPerMel
        }
        return logRegionStartMel + log(hertz / logRegionStartHertz) * melsPerLogStep
    }

    static func hertz(fromMel mel: Double) -> Double {
        guard mel >= logRegionStartMel else {
            return mel * linearHertzPerMel
        }
        return logRegionStartHertz * exp((mel - logRegionStartMel) / melsPerLogStep)
    }
}
