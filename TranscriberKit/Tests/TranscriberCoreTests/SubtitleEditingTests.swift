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
        #expect(after.lines[2] == line(2, 4, ""))
        let before = SubtitleEditing.insert(before: 0, in: lines)
        #expect(before.lines[0] == line(0, 0, ""))  // cannot start before zero
        #expect(SubtitleEditing.insert(after: 0, in: []).lines == [line(0, 2, "")])
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
        #expect(SubtitleEditing.charactersPerSecond(line(0, 2, "四个字儿 ab")) == 3)
    }
}
