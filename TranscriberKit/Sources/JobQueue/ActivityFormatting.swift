import Foundation
import TranscriberCore

/// Short, human-readable numbers for log messages.
enum ActivityFormatting {
    static func seconds(_ seconds: Double) -> String {
        seconds < 10 ? String(format: "%.1f s", seconds) : String(format: "%.0f s", seconds)
    }

    static func seconds(_ duration: Duration) -> String {
        seconds(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    /// 1:02:03 or 2:03.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, remainder) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    static func fileSize(of url: URL) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? Int64, attributes?[.type] as? FileAttributeType != .typeDirectory {
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        // A directory (MLX weights): add up its files.
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}
