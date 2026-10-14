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

/// Writes `<source name><suffix>.<format>` files, replacing existing ones.
enum SubtitleFileWriter {
    static func write(_ segments: [TimedText], for sourceURL: URL, settings: OutputSettings, nameSuffix: String = "") throws -> [URL] {
        let directory = settings.directory ?? sourceURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return try settings.formats.map { format in
            let url = directory.appendingPathComponent("\(stem)\(nameSuffix).\(format.fileExtension)")
            // A translation of movie.srt must never replace movie.srt itself.
            guard url.standardizedFileURL != sourceURL.standardizedFileURL else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
            try SubtitleRenderer.render(segments, as: format).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    /// Renders `segments` again into files written earlier, each in the
    /// format its extension names.
    static func rewrite(_ segments: [TimedText], to urls: [URL]) throws {
        for url in urls {
            guard let format = SubtitleFormat.allCases.first(where: { $0.fileExtension == url.pathExtension.lowercased() }) else {
                continue
            }
            try SubtitleRenderer.render(segments, as: format).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Text usable in a file name ("简体中文" stays, "/" and ":" go).
    static func safeNamePart(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "translated" : cleaned
    }
}
