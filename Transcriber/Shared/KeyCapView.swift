import AppKit

/// One key drawn as a keyboard cap: a rounded face with a darker lower edge
/// and the key's symbol, in system colors for light and dark mode.
final class KeyCapView: NSView {
    private enum Metrics {
        static let height: CGFloat = 20
        static let horizontalPadding: CGFloat = 6
        static let cornerRadius: CGFloat = 4
        static let borderWidth: CGFloat = 0.5
        /// How far the lower edge shows under the face.
        static let edgeDepth: CGFloat = 1
    }

    private let symbol: String

    private static var attributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeyCapView is created in code")
    }

    /// Single characters get square caps; words and F-keys grow wider.
    override var intrinsicContentSize: NSSize {
        let textWidth = ceil((symbol as NSString).size(withAttributes: Self.attributes).width)
        return NSSize(width: max(Metrics.height, textWidth + 2 * Metrics.horizontalPadding), height: Metrics.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = Metrics.borderWidth / 2
        let edge = bounds.insetBy(dx: inset, dy: inset)
        var face = edge
        face.size.height -= Metrics.edgeDepth
        if !isFlipped {
            face.origin.y += Metrics.edgeDepth
        }

        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: edge, xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius).fill()

        let facePath = NSBezierPath(roundedRect: face, xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius)
        NSColor.controlColor.setFill()
        facePath.fill()
        facePath.lineWidth = Metrics.borderWidth
        NSColor.separatorColor.setStroke()
        facePath.stroke()

        let size = (symbol as NSString).size(withAttributes: Self.attributes)
        let origin = NSPoint(x: face.midX - size.width / 2, y: face.midY - size.height / 2)
        (symbol as NSString).draw(at: origin, withAttributes: Self.attributes)
    }
}
