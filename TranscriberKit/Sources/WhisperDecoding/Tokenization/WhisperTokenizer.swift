import Foundation

/// Decodes Whisper tokens to text from a Hugging Face `tokenizer.json`, like
/// faster-whisper's `Tokenizer.decode`: tokens at or above `<|endoftext|>` are
/// dropped, the rest are turned back into bytes with the GPT-2 byte-level
/// mapping and decoded as UTF-8, invalid sequences becoming U+FFFD.
public struct WhisperTokenizer: Sendable {
    public let specialTokens: WhisperSpecialTokens
    public let vocabularySize: Int
    /// The bytes of each regular token, indexed by id (all ids below `<|endoftext|>`).
    private let tokenBytes: [[UInt8]]

    public init(contentsOf url: URL) throws(WhisperTokenizerError) {
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let model = root["model"] as? [String: Any],
            let vocabulary = model["vocab"] as? [String: Int],
            let addedTokenEntries = root["added_tokens"] as? [[String: Any]]
        else {
            throw .unreadableFile(url)
        }
        var addedTokens: [String: Int] = [:]
        for entry in addedTokenEntries {
            if let content = entry["content"] as? String, let id = entry["id"] as? Int {
                addedTokens[content] = id
            }
        }

        let specialTokens = try WhisperSpecialTokens(addedTokens: addedTokens)
        let unicodeToByte = ByteLevelAlphabet.unicodeToByte
        var tokenBytes = [[UInt8]](repeating: [], count: specialTokens.endOfText)
        for (token, id) in vocabulary where id < specialTokens.endOfText {
            var bytes: [UInt8] = []
            for character in token {
                guard let byte = unicodeToByte[character] else {
                    throw .unknownByteCharacter(character)
                }
                bytes.append(byte)
            }
            tokenBytes[id] = bytes
        }

        self.specialTokens = specialTokens
        self.vocabularySize = max(vocabulary.count, (addedTokens.values.max() ?? 0) + 1)
        self.tokenBytes = tokenBytes
    }

    public func decode(_ tokens: [Int]) -> String {
        let bytes = tokens.lazy
            .filter { $0 >= 0 && $0 < specialTokens.endOfText }
            .flatMap { tokenBytes[$0] }
        return String(decoding: Array(bytes), as: UTF8.self)
    }
}

/// GPT-2's reversible byte <-> printable character table used by Whisper's vocabulary.
enum ByteLevelAlphabet {
    static let unicodeToByte: [Character: UInt8] = {
        let printable = Array(0x21...0x7E) + Array(0xA1...0xAC) + Array(0xAE...0xFF)
        var table: [Character: UInt8] = [:]
        var nextUnprintable = 0
        for byte in 0...255 {
            let scalarValue: Int
            if printable.contains(byte) {
                scalarValue = byte
            } else {
                scalarValue = 256 + nextUnprintable
                nextUnprintable += 1
            }
            if let scalar = Unicode.Scalar(scalarValue) {
                table[Character(scalar)] = UInt8(byte)
            }
        }
        return table
    }()
}
