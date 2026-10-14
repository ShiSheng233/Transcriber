import Foundation
import SubtitleExport
import TranscriberCore

/// Where and in which formats subtitles are written.
public struct OutputSettings: Hashable, Sendable, Codable {
    public var formats: [SubtitleFormat]
    /// `nil` writes next to each source file, like the original.
    public var directory: URL?

    public init(formats: [SubtitleFormat], directory: URL?) {
        self.formats = formats
        self.directory = directory
    }
}

/// Writes `<source name>.<format>` files, replacing existing ones.
enum SubtitleFileWriter {
    static func write(_ segments: [TimedText], for sourceURL: URL, settings: OutputSettings) throws -> [URL] {
        let directory = settings.directory ?? sourceURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return try settings.formats.map { format in
            let url = directory.appendingPathComponent("\(stem).\(format.fileExtension)")
            try SubtitleRenderer.render(segments, as: format).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }
}
