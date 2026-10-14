import Testing
@testable import TranscriberCore

struct AudioTimeTests {
    @Test func convertsBetweenUnits() {
        let time = AudioTime(milliseconds: 1_500)
        #expect(time.samples == 24_000)
        #expect(time.seconds == 1.5)
        #expect(time.milliseconds == 1_500)
    }

    @Test func roundsSecondsToNearestSample() {
        #expect(AudioTime(seconds: 0.00003).samples == 0)
        #expect(AudioTime(seconds: 0.00004).samples == 1)
    }

    @Test func roundsHalfToEvenLikePython() {
        #expect(AudioTime(seconds: 0.5 / 16_000).samples == 0)
        #expect(AudioTime(seconds: 1.5 / 16_000).samples == 2)
        #expect(AudioTime(seconds: 2.5 / 16_000).samples == 2)
    }

    @Test func supportsArithmeticAndOrdering() {
        let start = AudioTime(seconds: 2)
        let duration = AudioTime(milliseconds: 500)
        #expect(start + duration == AudioTime(seconds: 2.5))
        #expect((start + duration) - start == duration)
        #expect(start < start + duration)
    }
}
