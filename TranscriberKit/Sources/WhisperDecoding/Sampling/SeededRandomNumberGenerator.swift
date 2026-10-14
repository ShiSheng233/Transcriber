/// SplitMix64: a small, fast generator whose sequence is fixed by its seed.
///
/// Temperature fallback samples tokens at random. CTranslate2 does too, without
/// a fixed seed, so the original's output can change between runs; seeding
/// each chunk makes ours repeatable and independent of how many chunks run at once.
public struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
