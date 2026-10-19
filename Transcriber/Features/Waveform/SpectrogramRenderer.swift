import AudioOverview
import CoreGraphics
import Foundation
import TranscriberCore

/// Pictures of the spectrogram for the waveform view, cached at two levels
/// so drawing stays cheap at any zoom and through hours of audio: tiles of a
/// fixed number of columns, coloured once and reused at every zoom; and the
/// visible stretch composed from them at the screen's pixel size, reused
/// while only the playhead moves.
final class SpectrogramRenderer {
    /// What the visible picture depends on besides the spectrogram.
    struct Viewport: Equatable {
        var visibleStart: AudioTime
        var pointsPerSecond: Double
        var size: CGSize
        /// Pixels per point.
        var scale: CGFloat
        var isDark: Bool
    }

    /// About 10 s of audio per tile.
    static let columnsPerTile = 512
    /// Tiles kept: each is 256 KB, so about 16 MB, more than a full-width
    /// view needs at the widest zoom.
    static let tileCapacity = 64

    private var spectrogram: Spectrogram?
    private var isDark = false
    private var palette: [UInt8] = []
    private var tiles: [Int: CGImage] = [:]
    private var recentTiles: [Int] = []
    private var visibleImage: (viewport: Viewport, image: CGImage)?

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    private static let bitsPerComponent = 8

    /// The visible stretch, `viewport.size` in points; `nil` for an empty view.
    func image(of spectrogram: Spectrogram, in viewport: Viewport) -> CGImage? {
        // Array equality checks for shared storage first: the same spectrogram compares at once.
        if spectrogram != self.spectrogram || viewport.isDark != isDark || palette.isEmpty {
            self.spectrogram = spectrogram
            isDark = viewport.isDark
            palette = SpectrogramColormap.palette(isDark: viewport.isDark)
            tiles = [:]
            recentTiles = []
            visibleImage = nil
        }
        if let visibleImage, visibleImage.viewport == viewport {
            return visibleImage.image
        }
        let image = compose(spectrogram, in: viewport)
        visibleImage = image.map { (viewport, $0) }
        return image
    }

    private func compose(_ spectrogram: Spectrogram, in viewport: Viewport) -> CGImage? {
        let width = Int((viewport.size.width * viewport.scale).rounded())
        let height = Int((viewport.size.height * viewport.scale).rounded())
        guard width > 0, height > 0, spectrogram.columnCount > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: Self.bitsPerComponent,
                                      bytesPerRow: 0, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo) else {
            return nil
        }
        context.interpolationQuality = .medium
        let pixelsPerSecond = viewport.pointsPerSecond * Double(viewport.scale)
        // Whole pixels, so neighbouring tiles meet without a seam.
        func x(ofColumn column: Int) -> CGFloat {
            CGFloat(((Spectrogram.startTime(ofColumn: column) - viewport.visibleStart).seconds * pixelsPerSecond).rounded())
        }
        let visibleEnd = viewport.visibleStart + AudioTime(seconds: Double(width) / pixelsPerSecond)
        let tileCount = (spectrogram.columnCount + Self.columnsPerTile - 1) / Self.columnsPerTile
        let firstTile = max(Spectrogram.column(at: viewport.visibleStart) / Self.columnsPerTile, 0)
        let lastTile = min(Spectrogram.column(at: visibleEnd) / Self.columnsPerTile, tileCount - 1)
        guard firstTile <= lastTile else { return nil }
        for index in firstTile...lastTile {
            guard let tile = tile(index, of: spectrogram) else { continue }
            let firstColumn = index * Self.columnsPerTile
            let minX = x(ofColumn: firstColumn)
            let maxX = x(ofColumn: firstColumn + tile.width)
            context.draw(tile, in: CGRect(x: minX, y: 0, width: maxX - minX, height: CGFloat(height)))
        }
        return context.makeImage()
    }

    /// One tile at one pixel per column and band, the highest band in the top row.
    private func tile(_ index: Int, of spectrogram: Spectrogram) -> CGImage? {
        if let cached = tiles[index] {
            recentTiles.removeAll { $0 == index }
            recentTiles.append(index)
            return cached
        }
        let firstColumn = index * Self.columnsPerTile
        let width = min(Self.columnsPerTile, spectrogram.columnCount - firstColumn)
        guard width > 0 else { return nil }
        let height = Spectrogram.bandCount
        let bytesPerPixel = SpectrogramColormap.bytesPerPixel
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for column in 0..<width {
            for band in 0..<height {
                let level = Int(spectrogram.level(column: firstColumn + column, band: band))
                let pixel = (height - 1 - band) * bytesPerRow + column * bytesPerPixel
                for channel in 0..<bytesPerPixel {
                    pixels[pixel + channel] = palette[level * bytesPerPixel + channel]
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: Self.bitsPerComponent,
                                  bitsPerPixel: Self.bitsPerComponent * bytesPerPixel, bytesPerRow: bytesPerRow,
                                  space: Self.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return nil
        }
        tiles[index] = image
        recentTiles.append(index)
        if recentTiles.count > Self.tileCapacity {
            tiles[recentTiles.removeFirst()] = nil
        }
        return image
    }
}
