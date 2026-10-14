import Testing
@testable import TranscriberCore

struct SubtitleEditingTests {
    private func line(_ start: Double, _ end: Double, _ text: String) -> TimedText {
        TimedText(start: AudioTime(seconds: start), end: AudioTime(seconds: end), text: text)
    }

    private lazy var lines = [line(0, 1, "a"), line(1, 2, "b"), line(5, 6, "c")]

    @Test mutating func insertsAfterAndBefore() {
        let after = SubtitleEditing.insert(after: 1, in: lines)
        #expect(after.lines.count == 4 && after.selection == [2])
        #expect(after.lines[2] == line(2, 5, ""))  // 3 s, up to the next line's start
        #expect(SubtitleEditing.insert(after: 0, in: lines).lines[1] == line(1, 4, ""))  // no gap to fill: full length
        let before = SubtitleEditing.insert(before: 2, in: lines)
        #expect(before.lines[2] == line(2, 5, ""))  // from the previous end
        #expect(SubtitleEditing.insert(before: 0, in: lines).lines[0] == line(0, 0, ""))  // never before zero
        #expect(SubtitleEditing.insert(after: 0, in: []).lines == [line(0, 3, "")])
    }

    @Test mutating func duplicatesAndDeletes() {
        let duplicated = SubtitleEditing.duplicate([0, 2], in: lines)
        #expect(duplicated.lines.map(\.text) == ["a", "a", "b", "c", "c"])
        #expect(duplicated.selection == [1, 4])
        let deleted = SubtitleEditing.delete([1, 2], in: lines)
        #expect(deleted.lines.map(\.text) == ["a"] && deleted.selection == [0])
        #expect(SubtitleEditing.delete([0, 1, 2], in: lines).selection.isEmpty)
    }

    @Test mutating func mergesWithSpacesOnlyBetweenLatinText() {
        let merged = SubtitleEditing.merge([2, 0, 1], in: lines)
        #expect(merged.lines == [line(0, 6, "a b c")])
        let cjk = SubtitleEditing.merge([0, 1], in: [line(0, 1, "你好"), line(1, 2, "世界")])
        #expect(cjk.lines.map(\.text) == ["你好世界"])
        #expect(SubtitleEditing.merge([1], in: lines).lines == lines)  // one line: nothing to join
    }

    @Test func splitsAtTheCursorWithEstimatedTimes() {
        let result = SubtitleEditing.split(0, atCharacter: 6, in: [line(0, 4, "Hello world.")])
        #expect(result.lines.map(\.text) == ["Hello", "world."])
        #expect(result.lines[0].end == AudioTime(seconds: 2))  // 6 of 12 characters
        #expect(result.lines[1].start == AudioTime(seconds: 2) && result.lines[1].end == AudioTime(seconds: 4))
    }

    @Test mutating func shiftsSelectedOrAllAndKeepsOrder() {
        let all = SubtitleEditing.shift([], by: -500, in: lines)
        #expect(all.lines.map(\.start.milliseconds) == [0, 500, 4_500])
        #expect(all.lines[0].end.milliseconds == 1_000)  // clamped start, duration kept
        let one = SubtitleEditing.shift([2], by: -4_500, in: lines)
        #expect(one.lines.map(\.text) == ["a", "c", "b"])  // re-sorted
        #expect(one.selection == [1])
    }

    @Test mutating func setsTimesWithoutCrossing() {
        let result = SubtitleEditing.setTimes(0, start: AudioTime(seconds: 3), in: lines)
        #expect(result.lines[0] == line(3, 3, "a"))
        #expect(SubtitleEditing.charactersPerSecond(line(0, 2, "四个字儿，ab！")) == 3)  // no spaces or punctuation
        #expect(SubtitleEditing.charactersPerSecond(line(0, 0.1, "abc")) == nil)
    }

    @Test mutating func makesTimesContinuousAndFindsOverlaps() {
        #expect(SubtitleEditing.makeContinuous([2], changing: .start, in: lines).lines[2] == line(2, 6, "c"))
        #expect(SubtitleEditing.makeContinuous([1], changing: .end, in: lines).lines[1] == line(1, 5, "b"))
        let overlapping = [line(0, 2, "a"), line(1, 3, "b"), line(3, 4, "c")]
        #expect(SubtitleEditing.overlapping(1, in: overlapping) == [0])
        #expect(SubtitleEditing.longestLineLength("ab\nabcd") == 4)
    }
}
