import AudioOverview

/// The colours of the spectrogram's levels: matplotlib's magma, a
/// perceptually uniform map (equal steps in level look like equal steps in
/// colour, and it reads in grey too), dark to bright in dark mode and
/// reversed, bright to dark like ink on paper, in light mode. The quietest
/// levels fade out, so silence is the view's own background in both.
enum SpectrogramColormap {
    /// The levels spread over the colours, in dB relative to a full-scale
    /// sine; Audacity's defaults (80 dB range, 20 dB gain). Quieter is
    /// transparent; louder is the brightest (in light mode the darkest) colour.
    static let displayFloorDecibels: Float = -100
    static let displayCeilingDecibels: Float = -20
    /// Over this lowest part of the range the colour fades in from nothing.
    static let fadeInFraction: Float = 0.2
    static let bytesPerPixel = 4

    /// Premultiplied RGBA bytes for each of the 256 levels.
    static func palette(isDark: Bool) -> [UInt8] {
        (0...Int(Spectrogram.maximumLevel)).flatMap { level -> [UInt8] in
            let decibels = Spectrogram.decibels(ofLevel: UInt8(level))
            let position = min(max((decibels - displayFloorDecibels) / (displayCeilingDecibels - displayFloorDecibels), 0), 1)
            let alpha = min(position / fadeInFraction, 1)
            let colour = magma(isDark ? position : 1 - position)
            return [colour.red, colour.green, colour.blue, 1].map { UInt8((min(max($0, 0), 1) * alpha * Float(UInt8.max)).rounded()) }
        }
    }

    /// Matt Zucker's degree-6 polynomial fit of magma (shadertoy.com/view/WlfXRN),
    /// within about 1% of matplotlib's table; `position` is 0…1.
    static func magma(_ position: Float) -> (red: Float, green: Float, blue: Float) {
        let coefficients: [(red: Float, green: Float, blue: Float)] = [
            (-0.002136485053939582, -0.000749655052795221, -0.005386127855323933),
            (0.2516605407371642, 0.6775232436837668, 2.494026599312351),
            (8.353717279216625, -3.577719514958484, 0.3144679030132573),
            (-27.66873308576866, 14.26473078096533, -13.64921318813922),
            (52.17613981234068, -27.94360607168351, 12.94416944238394),
            (-50.76852536473588, 29.04658282127291, 4.23415299384598),
            (18.65570506591883, -11.48977351997711, -5.601961508734096),
        ]
        // Horner's rule, highest power first.
        return coefficients.reversed().reduce((red: Float(0), green: Float(0), blue: Float(0))) { sum, term in
            (sum.red * position + term.red, sum.green * position + term.green, sum.blue * position + term.blue)
        }
    }
}
