import Testing
@testable import TranscriberCore

struct SubtitleArrangingTests {
    private func line(_ start: Double, _ end: Double, _ text: String = "") -> TimedText {
        TimedText(start: AudioTime(seconds: start), end: AudioTime(seconds: end), text: text)
    }

    @Test func joinsKeepingTheFirstText() {
        let result = SubtitleEditing.mergeKeepingFirstText([1, 0], in: [line(0, 1, "a"), line(1, 3, "b"), line(4, 5, "c")])
        #expect(result.lines == [line(0, 3, "a"), line(4, 5, "c")])
        #expect(result.selection == [0])
    }

    @Test func swapsTheTextsOfExactlyTwoLines() {
        let lines = [line(0, 1, "a"), line(1, 2, "b"), line(2, 3, "c")]
        #expect(SubtitleEditing.swapTexts([0, 2], in: lines).lines == [line(0, 1, "c"), line(1, 2, "b"), line(2, 3, "a")])
        #expect(SubtitleEditing.swapTexts([0], in: lines).lines == lines)
        #expect(SubtitleEditing.isSortedByStart(lines))
        #expect(!SubtitleEditing.isSortedByStart(lines.reversed()))
    }

    @Test func sortsByStartKeepingTheSelection() {
        let result = SubtitleEditing.sortedByStart([line(5, 6, "c"), line(0, 2, "a"), line(0, 1, "z")], keeping: [0])
        #expect(result.lines.map(\.text) == ["z", "a", "c"])
        #expect(result.selection == [2])
    }

    @Test func splitsAtATimeWithTheTextAtTheCursor() {
        let lines = [line(0, 4, "Hello world")]
        let atCursor = SubtitleEditing.split(0, at: AudioTime(seconds: 1), atCharacter: 6, in: lines)
        #expect(atCursor.lines == [line(0, 1, "Hello"), line(1, 4, "world")])
        let wholeText = SubtitleEditing.split(0, at: AudioTime(seconds: 3), atCharacter: 11, in: lines)
        #expect(wholeText.lines == [line(0, 3, "Hello world"), line(3, 4, "Hello world")])
        #expect(SubtitleEditing.split(0, at: AudioTime(seconds: 5), atCharacter: 0, in: lines).lines == lines)  // outside the line
        let estimated = SubtitleEditing.split(0, at: AudioTime(seconds: 2), atCharacter: nil, in: [line(0, 4, "あいうえ")])
        #expect(estimated.lines.map(\.text) == ["あい", "うえ"])  // halfway through the time, halfway through the text
    }

    @Test func shiftsChosenEdges() {
        let lines = [line(1, 2, "a"), line(3, 4, "b")]
        let later = AudioTime(milliseconds: 500)
        #expect(SubtitleEditing.shift([0], by: later, changing: .both, in: lines).lines[0] == line(1.5, 2.5, "a"))
        #expect(SubtitleEditing.shift([0], by: later, changing: .end, in: lines).lines[0] == line(1, 2.5, "a"))
        #expect(SubtitleEditing.shift([0], by: AudioTime(seconds: 2), changing: .start, in: lines).lines[0] == line(2, 2, "a"))  // never past the end
        let earlier = SubtitleEditing.shift([1], by: AudioTime(seconds: -3), changing: .both, in: lines)
        #expect(earlier.lines == [line(0, 1, "b"), line(1, 2, "a")])  // clamped at zero, re-sorted
        #expect(earlier.selection == [0])
    }

    @Test func selectsByCriteria() {
        let lines = [line(0, 2, "ab"), line(1, 1.2, "abcdefgh"), line(3, 13, "x"), line(14, 15, "うん")]
        #expect(SubtitleSelection.matching(.overlapping, in: lines) == [0, 1])
        #expect(SubtitleSelection.matching(.readingSpeedAbove(20), in: lines) == [1])
        #expect(SubtitleSelection.matching(.durationBelow(AudioTime(milliseconds: 500)), in: lines) == [1])
        #expect(SubtitleSelection.matching(.durationAbove(AudioTime(seconds: 7)), in: lines) == [2])
        #expect(SubtitleSelection.matching(.textMatching { $0.contains("う") }, in: lines) == [3])
        #expect(SubtitleSelection.combined([1, 2], with: [0, 1], mode: .add) == [0, 1, 2])
        #expect(SubtitleSelection.combined([1, 2], with: [0, 1], mode: .subtract) == [0])
        #expect(SubtitleSelection.combined([1, 2], with: [0, 1], mode: .intersect) == [1])
        #expect(SubtitleSelection.combined([1, 2], with: [0, 1], mode: .replace) == [1, 2])
    }

    @Test func findsOriginalsByTimesThenByMiddle() {
        let originals = [line(0, 1, "一"), line(1, 2, "二"), line(2, 3, "三")]
        let edited = [line(0, 1, "one"), line(0.9, 3, "two three"), line(5, 6, "added")]
        #expect(SubtitleSources.originals(of: edited, in: originals) == ["一", "二\n三", nil])
        #expect(SubtitleSources.originals(of: edited, in: []) == [nil, nil, nil])
    }
}
