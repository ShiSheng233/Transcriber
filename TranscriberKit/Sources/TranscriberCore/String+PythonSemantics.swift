/// Python `str` behavior the original relies on, which differs from Swift's:
/// Python's whitespace set includes U+001C...U+001F, and `startswith` /
/// `endswith` compare code points, while Swift compares grapheme clusters under
/// canonical equivalence ("e\u{301}" == "é" in Swift, not in Python).
extension String {
    /// `str.strip()`.
    public var pythonStripped: String {
        let scalars = unicodeScalars
        guard
            let first = scalars.firstIndex(where: { !$0.isPythonWhitespace }),
            let last = scalars.lastIndex(where: { !$0.isPythonWhitespace })
        else {
            return ""
        }
        return String(scalars[first...last])
    }

    /// `" ".join(text.strip().split())`: trims and collapses whitespace runs to one space.
    public var pythonWhitespaceCollapsed: String {
        var words: [String.UnicodeScalarView.SubSequence] = []
        var wordStart: String.UnicodeScalarView.Index?
        for index in unicodeScalars.indices {
            if unicodeScalars[index].isPythonWhitespace {
                if let start = wordStart {
                    words.append(unicodeScalars[start..<index])
                    wordStart = nil
                }
            } else if wordStart == nil {
                wordStart = index
            }
        }
        if let start = wordStart {
            words.append(unicodeScalars[start...])
        }
        return words.map(String.init).joined(separator: " ")
    }

    /// `str.startswith(prefix)`.
    public func pythonHasPrefix(_ prefix: String) -> Bool {
        unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// `str.endswith(suffix)`.
    public func pythonHasSuffix(_ suffix: String) -> Bool {
        unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed())
    }
}

extension Unicode.Scalar {
    /// `str.isspace()`: Unicode White_Space plus the ASCII information separators.
    var isPythonWhitespace: Bool {
        properties.isWhitespace || (0x1C...0x1F).contains(value)
    }
}
