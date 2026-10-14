import AppKit

/// The current subtitle drawn over the video, like a player's subtitles:
/// white text on a translucent dark plate near the bottom of the picture.
final class SubtitleOverlayView: NSView {
    private let plate = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        plate.wantsLayer = true
        plate.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        plate.layer?.cornerRadius = 6
        plate.layer?.cornerCurve = .continuous
        plate.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(plate)
        plate.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: plate.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -10),
            plate.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Above the inline playback controls.
            plate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -64),
            plate.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.85),
        ])
        plate.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SubtitleOverlayView is created in code")
    }

    /// Clicks go through to the player.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    var text: String? {
        didSet {
            label.stringValue = text ?? ""
            plate.isHidden = (text ?? "").isEmpty
        }
    }
}
