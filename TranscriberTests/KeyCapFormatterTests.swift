import Testing

/// Key equivalents as the menus hold them, turned into the caps a Mac shows.
struct KeyCapFormatterTests {
    private typealias Modifiers = KeyCapFormatter.Modifiers

    @Test func letterWithCommandIsUppercase() {
        #expect(KeyCapFormatter.keyCaps(keyEquivalent: "s", modifiers: .command) == ["⌘", "S"])
    }

    @Test func modifiersFollowApplesOrder() {
        let all: Modifiers = [.command, .shift, .option, .control]
        #expect(KeyCapFormatter.keyCaps(keyEquivalent: "1", modifiers: all) == ["⌃", "⌥", "⇧", "⌘", "1"])
    }

    @Test func uppercaseLetterImpliesShift() {
        #expect(KeyCapFormatter.keyCaps(keyEquivalent: "Z", modifiers: .command) == ["⇧", "⌘", "Z"])
    }

    @Test func rawValuesMatchAppKit() {
        // NSEvent.ModifierFlags: shift 1<<17, control 1<<18, option 1<<19, command 1<<20.
        #expect(Modifiers(rawValue: 0x0010_0000) == .command)
        #expect(Modifiers(rawValue: 0x0018_0000) == [.command, .option])
        #expect(KeyCapFormatter.keyCaps(keyEquivalent: "a", modifiers: Modifiers(rawValue: 0x0014_0000)) == ["⌃", "⌘", "A"])
    }

    @Test(arguments: [
        ("\r", "↩"),
        ("\u{3}", "⌤"),
        ("\u{1b}", "⎋"),
        ("\u{8}", "⌫"),
        ("\u{7f}", "⌫"),
        ("\t", "⇥"),
        ("\u{19}", "⇤"),
        ("\u{F700}", "↑"),
        ("\u{F701}", "↓"),
        ("\u{F702}", "←"),
        ("\u{F703}", "→"),
        ("\u{F704}", "F1"),
        ("\u{F70F}", "F12"),
        ("\u{F726}", "F35"),
        ("\u{F728}", "⌦"),
        ("\u{F72C}", "⇞"),
        ("=", "="),
        (",", ","),
    ])
    func specialKeys(keyEquivalent: String, symbol: String) {
        #expect(KeyCapFormatter.keyCaps(keyEquivalent: keyEquivalent, modifiers: []) == [symbol])
    }

    @Test func spaceIsSpelledOut() {
        #expect(KeyCapFormatter.keyCaps(keyEquivalent: " ", modifiers: []).count == 1)
        #expect(KeyCapFormatter.keyCaps(keyEquivalent: " ", modifiers: []) != [" "])
    }

    @Test func noKeyLeavesTheModifiers() {
        #expect(KeyCapFormatter.keyCaps(keyEquivalent: "", modifiers: .option) == ["⌥"])
        #expect(KeyCapFormatter.keyCaps(keyEquivalent: "", modifiers: []).isEmpty)
    }

    @Test func textRunsTheCapsTogether() {
        #expect(KeyCapFormatter.text(keyEquivalent: "\r", modifiers: [.command, .shift]) == "⇧⌘↩")
    }
}
