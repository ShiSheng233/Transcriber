import Testing
@testable import TranscriberCore

struct TermVariantsTests {
    private static func spellings(_ group: TermVariants.Group?) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: (group?.spellings ?? []).map { ($0.text, $0.count) })
    }

    @Test func findsKatakanaWrittenWithDifferentWidthsDotsAndLongMarks() {
        let lines = [
            "マリアンヌ・ローズが来た",
            "ﾏﾘｱﾝﾇ・ﾛｰｽﾞだよ",
            "マリアンヌローズ？",
            "マリアンヌ・ローズ、おはよう",
            "ゲーム～ゲーム",
        ]
        let groups = TermVariants.groups(in: lines)
        let rose = groups.first { $0.key == TermVariants.fold("マリアンヌローズ") }

        #expect(Self.spellings(rose) == ["マリアンヌ・ローズ": 2, "ﾏﾘｱﾝﾇ・ﾛｰｽﾞ": 1, "マリアンヌローズ": 1])
        #expect(rose?.suggestedSpelling == "マリアンヌ・ローズ")
        #expect(groups.count == 1)  // "ゲーム" and "ゲーム～ゲーム" are one run, spelled one way
    }

    @Test func matchesHiraganaOnlyAsAWholeRunOfAKatakanaTerm() {
        let lines = ["ナナミ、来て", "ななみ、待って", "かななみは別", "ナナミちゃん"]
        let group = TermVariants.groups(in: lines).first

        #expect(Self.spellings(group) == ["ナナミ": 2, "ななみ": 1])
    }

    @Test func leavesOrdinaryWordsAndShortRunsAlone() {
        let lines = ["ダメ、だめ", "OK ok", "今日は天気がいい", "今日は天気がいい", "スゴイ"]
        #expect(TermVariants.groups(in: lines).isEmpty)
    }

    @Test func findsLatinDifferingInWidthOrCase() {
        let lines = ["Yuika is here", "ＹＵＩＫＡ!", "yuikaX"]
        let group = TermVariants.groups(in: lines).first
        #expect(Self.spellings(group) == ["Yuika": 1, "ＹＵＩＫＡ": 1])
    }

    @Test func aGlossaryTermNeedsOnlyOneOtherSpellingAndIsSuggested() {
        let lines = ["ゆいちゃん、おはよう", "ユイちゃん", "かゆいちゃん"]
        let groups = TermVariants.groups(in: lines, glossaryTerms: ["ユイちゃん", "結衣"])

        #expect(groups.count == 1)
        #expect(Self.spellings(groups.first) == ["ゆいちゃん": 1, "ユイちゃん": 1])
        #expect(groups.first?.glossarySpelling == "ユイちゃん")
        #expect(groups.first?.suggestedSpelling == "ユイちゃん")
    }

    @Test func listsAnUnusedGlossarySpellingSoItCanBeChosen() {
        let group = TermVariants.groups(in: ["ｱﾘｽ"], glossaryTerms: ["アリス"]).first
        #expect(Self.spellings(group) == ["ｱﾘｽ": 1, "アリス": 0])
    }

    @Test func unifiesOnlyWholeRuns() {
        let key = TermVariants.fold("ナナミ")
        let unified = TermVariants.unifying(["ななみ、待って", "かななみは別", "ﾅﾅﾐちゃん"], to: [key: "ナナミ"])
        #expect(unified == ["ナナミ、待って", "かななみは別", "ナナミちゃん"])
    }
}
