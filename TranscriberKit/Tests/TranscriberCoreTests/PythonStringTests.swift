import Testing
@testable import TranscriberCore

struct PythonStringTests {
    @Test func stripsPythonWhitespace() {
        #expect("\u{3000} 字幕 \n".pythonStripped == "字幕")
        #expect("\u{1C}text\u{1F}".pythonStripped == "text")
        #expect(" \u{3000} ".pythonStripped.isEmpty)
    }

    @Test func collapsesWhitespaceRuns() {
        #expect("  你好\u{3000}\u{3000}世界  ok ".pythonWhitespaceCollapsed == "你好 世界 ok")
    }

    @Test func comparesCodePointsNotGraphemes() {
        let decomposed = "e\u{301}"
        #expect(!decomposed.pythonHasPrefix("\u{E9}"))
        #expect(decomposed.pythonHasPrefix("e"))
        #expect(decomposed.pythonHasSuffix("\u{301}"))
        #expect("こんにちは".pythonHasSuffix("ちは"))
    }
}
