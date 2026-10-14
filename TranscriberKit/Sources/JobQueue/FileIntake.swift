import Foundation
import SubtitleExport

/// Sorts added files into what the queue should do with them.
///
/// - A subtitle file (SRT, VTT) is opened for editing; a media file with the
///   same name next to it is used for the preview.
/// - A media file is transcribed, unless a subtitle file with the same name
///   sits next to it: then the user decides (edit or translate those
///   subtitles, or transcribe again).
/// - Folders are searched; there, translations the app wrote earlier
///   ("movie.简体中文.srt" next to "movie.mp4") are skipped.
public struct FileIntake: Equatable, Sendable {
    public struct MediaWithSubtitles: Equatable, Sendable {
        public let mediaURL: URL
        public let subtitleURL: URL
    }

    public struct SubtitleFile: Equatable, Sendable {
        public let subtitleURL: URL
        public let mediaURL: URL?

        public init(subtitleURL: URL, mediaURL: URL?) {
            self.subtitleURL = subtitleURL
            self.mediaURL = mediaURL
        }
    }

    public static let mediaExtensions: Set<String> = [
        "mp3", "wav", "flac", "m4a", "aac", "ogg", "opus", "wma", "mp4", "mkv", "avi", "mov", "webm", "flv", "wmv", "ts",
    ]

    public var mediaToTranscribe: [URL] = []
    public var mediaWithSubtitles: [MediaWithSubtitles] = []
    public var subtitleFiles: [SubtitleFile] = []

    public var isEmpty: Bool {
        mediaToTranscribe.isEmpty && mediaWithSubtitles.isEmpty && subtitleFiles.isEmpty
    }

    public init(_ urls: [URL]) {
        var media: [URL] = []
        var subtitles: [URL] = []
        for url in urls {
            let (foundMedia, foundSubtitles) = Self.files(in: url)
            media += foundMedia
            subtitles += foundSubtitles
        }
        var claimedSubtitles: Set<URL> = []
        for mediaURL in media {
            if let subtitleURL = Self.sibling(of: mediaURL, withExtensions: SubtitleParser.fileExtensions) {
                mediaWithSubtitles.append(MediaWithSubtitles(mediaURL: mediaURL, subtitleURL: subtitleURL))
                claimedSubtitles.insert(subtitleURL.standardizedFileURL)
            } else {
                mediaToTranscribe.append(mediaURL)
            }
        }
        for subtitleURL in subtitles where !claimedSubtitles.contains(subtitleURL.standardizedFileURL) {
            subtitleFiles.append(SubtitleFile(
                subtitleURL: subtitleURL,
                mediaURL: Self.sibling(of: subtitleURL, withExtensions: Self.mediaExtensions)
            ))
        }
    }

    /// Media and subtitle files: the file itself, or those inside a folder.
    private static func files(in url: URL) -> (media: [URL], subtitles: [URL]) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return ([], [])
        }
        guard isDirectory.boolValue else {
            let fileExtension = url.pathExtension.lowercased()
            return (mediaExtensions.contains(fileExtension) ? [url] : [], SubtitleParser.fileExtensions.contains(fileExtension) ? [url] : [])
        }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let files = ((enumerator?.allObjects as? [URL]) ?? [])
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let media = files.filter { mediaExtensions.contains($0.pathExtension.lowercased()) }
        let subtitles = files.filter { SubtitleParser.fileExtensions.contains($0.pathExtension.lowercased()) && !isEarlierTranslation($0) }
        return (media, subtitles)
    }

    /// "movie.简体中文.srt" when "movie.srt" or a "movie" media file is beside it.
    private static func isEarlierTranslation(_ subtitleURL: URL) -> Bool {
        // By string: URL.pathExtension does not accept "简体中文" as an extension.
        let stem = subtitleURL.deletingPathExtension().lastPathComponent
        guard let dot = stem.lastIndex(of: "."), dot != stem.startIndex else {
            return false
        }
        let base = subtitleURL.deletingLastPathComponent().appendingPathComponent(String(stem[..<dot]))
        return sibling(ofStem: base, withExtensions: SubtitleParser.fileExtensions.union(mediaExtensions)) != nil
    }

    /// A file with the same name and one of `extensions`, in the same folder.
    private static func sibling(of url: URL, withExtensions extensions: Set<String>) -> URL? {
        sibling(ofStem: url.deletingPathExtension(), withExtensions: extensions)
    }

    private static func sibling(ofStem stem: URL, withExtensions extensions: Set<String>) -> URL? {
        let folder = stem.deletingLastPathComponent()
        let name = stem.lastPathComponent
        let candidates = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        // Rebuilt from `folder`: the listing may spell it differently
        // (/private/var for /var), and URLs are compared by path.
        return candidates
            .map { folder.appendingPathComponent($0.lastPathComponent) }
            .filter { $0.deletingPathExtension().lastPathComponent == name && extensions.contains($0.pathExtension.lowercased()) }
            .min { $0.lastPathComponent < $1.lastPathComponent }
    }
}
