import CryptoKit
import Foundation

/// How the disk caches name and expire their files: a media file is known by
/// its path, size and modification date, so a changed file is read again.
enum MediaCacheFiles {
    /// The cache file for `mediaURL` in `directory`; `nil` when the media
    /// file cannot be found.
    static func url(for mediaURL: URL, in directory: URL, fileExtension: String) -> URL? {
        // Read fresh each time: URL resource values are cached per URL.
        let attributes = try? FileManager.default.attributesOfItem(atPath: mediaURL.path)
        guard let size = attributes?[.size] as? Int, let modified = attributes?[.modificationDate] as? Date else {
            return nil
        }
        let identity = "\(mediaURL.standardizedFileURL.path)\n\(size)\n\(modified.timeIntervalSinceReferenceDate)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension(fileExtension)
    }

    /// The app's own folder in the user's Caches.
    static func standardDirectory(named name: String) -> URL {
        URL.cachesDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Transcriber", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Creates the folder if needed and deletes the files with these
    /// extensions not used for `lifetime`.
    static func prepare(_ directory: URL, fileExtensions: Set<String>, lifetime: Duration) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cutoff = Date.now.addingTimeInterval(-Double(lifetime.components.seconds))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files where fileExtensions.contains(file.pathExtension) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// A cache file's contents, touched on use so files in use do not expire.
    static func read(_ file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
        return data
    }
}
