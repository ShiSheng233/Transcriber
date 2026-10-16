import CryptoKit
import Foundation

/// Complete language-model replies on disk, so a run that was stopped, failed
/// part way or is started again does not pay for batches it already has.
///
/// A reply is found by what was asked (model, instructions, lines and their
/// context), not by the running summaries: those depend on earlier replies,
/// and a resumed run should reuse a batch even if an earlier one changed.
public struct LLMReplyCache: Sendable {
    /// Replies older than this are deleted when the cache is opened.
    public static let defaultLifetime: Duration = .seconds(14 * 24 * 60 * 60)

    private let directory: URL

    /// Creates the folder if needed and deletes expired replies.
    public init(directory: URL, lifetime: Duration = Self.defaultLifetime) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.deleteReplies(in: directory, olderThan: Date.now.addingTimeInterval(-Double(lifetime.components.seconds)))
    }

    /// The folder the app uses, under the user's Caches.
    public static var standardDirectory: URL {
        URL.cachesDirectory.appendingPathComponent("Transcriber/LLMReplies", isDirectory: true)
    }

    struct Key: Encodable {
        let model: String
        let instructions: String
        let request: String
    }

    func reply(for key: Key) -> Data? {
        try? Data(contentsOf: fileURL(for: key))
    }

    func store(_ reply: Data, for key: Key) {
        try? reply.write(to: fileURL(for: key), options: .atomic)
    }

    private func fileURL(for key: Key) -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: (try? encoder.encode(key)) ?? Data())
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    private static func deleteReplies(in directory: URL, olderThan cutoff: Date) {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
