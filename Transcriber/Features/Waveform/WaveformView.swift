import AppKit
import AudioOverview
import TranscriberCore

/// The audio under the player with the subtitle lines over it, after
/// Aegisub's audio display: drag the active line's edges to time it (⇧ moves
/// a touching neighbour too, ⌥ turns snapping off), drag inside it to move
/// the selected lines, click to move the playhead or, on a line's label
/// strip, to select that line; scroll to pan, ⌥/⌘-scroll or pinch to zoom.
///
/// While a handle is dragged the editor shows the new times (grid and edit
/// box follow); releasing applies them as one undo step.
final class WaveformView: NSView {
    private enum Metrics {
        static let rulerHeight: CGFloat = 16
        static let soundBarHeight: CGFloat = 4
        static let handleHitWidth: CGFloat = 5
        static let handleWidth: CGFloat = 2
        static let snappedHandleWidth: CGFloat = 3
        static let grabTabSize = NSSize(width: 8, height: 6)
        static let snapDistance: CGFloat = 6
        /// The strip under the ruler where a click selects a line.
        static let labelStripHeight: CGFloat = 14
        /// A press that moves less than this is a click, not a drag.
        static let dragThreshold: CGFloat = 3
        static let autoscrollMargin: CGFloat = 24
        static let autoscrollStep: CGFloat = 4
        /// Lines narrower than this show only their number.
        static let minimumWidthForText: CGFloat = 80
        static let labelInset: CGFloat = 3
        /// The ruler aims for at least this much room between labels.
        static let minimumTickSpacing: CGFloat = 60
        static let scrollZoomSensitivity: CGFloat = 0.01
        /// Between the status message and the line through the middle.
        static let statusSpacing: CGFloat = 4
    }

    /// Ruler intervals to choose from, in seconds.
    private static let tickIntervals: [Double] = [0.1, 0.5, 1, 2, 5, 10, 30, 60, 300]
    /// How far ←/→ move the playhead (⇧ for the larger step).
    private static let nudge = AudioTime(milliseconds: 100)
    private static let largeNudge = AudioTime(seconds: 1)

    private let editor: SubtitleEditorViewModel
    private let waveform: WaveformViewModel
    /// Asked to move the playhead.
    var onSeek: (AudioTime) -> Void = { _ in }
    /// The user picked a line on the waveform (double-click).
    var onSelectLine: (Int) -> Void = { _ in }

    /// Updated by the player every frame while playing.
    var playheadTime = AudioTime.zero {
        didSet {
            if playheadTime != oldValue {
                needsDisplay = true
            }
        }
    }

    private enum Drag {
        case seeking
        case handle(index: Int, isStart: Bool, fixed: AudioTime)
        /// Inside the active line: a click seeks, a drag moves the selection.
        case shift(grabbedAt: AudioTime, downX: CGFloat, isMoving: Bool)
    }

    private var drag: Drag?
    private var snappedTime: AudioTime?
    private var dragLabel: String?
    private var displayedActiveIndex: Int?
    private var binder: ObservationBinder?
    /// Under the failure message.
    private let retryButton = NSButton(title: String(localized: "Try Again"), target: nil, action: nil)

    init(editor: SubtitleEditorViewModel, waveform: WaveformViewModel) {
        self.editor = editor
        self.waveform = waveform
        super.init(frame: .zero)
        retryButton.target = self
        retryButton.action = #selector(retryClicked(_:))
        retryButton.controlSize = .small
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(retryButton)
        // Just below the middle of the area under the ruler, where the message sits above.
        NSLayoutConstraint.activate([
            retryButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: centerYAnchor, constant: Metrics.rulerHeight / 2 + Metrics.statusSpacing),
        ])
        binder = ObservationBinder { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WaveformView is created in code")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var width: Double { Double(bounds.width) }

    /// Reads what the drawing uses, so any change redraws.
    private func render() {
        _ = (editor.displayedLines, editor.selection, editor.isEditable, editor.playbackTime)
        _ = (waveform.waveform, waveform.snapSpans, waveform.isLoading, waveform.pointsPerSecond, waveform.visibleStart)
        if editor.activeIndex != displayedActiveIndex {
            displayedActiveIndex = editor.activeIndex
            if let line = editor.activeLine {
                waveform.reveal(line, width: width)
            }
        }
        if drag == nil {
            playheadTime = editor.playbackTime
        }
        retryButton.isHidden = waveform.loadFailureMessage == nil
        needsDisplay = true
    }

    @objc private func retryClicked(_ sender: Any?) {
        waveform.retry()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let body = NSRect(x: 0, y: Metrics.rulerHeight, width: bounds.width, height: bounds.height - Metrics.rulerHeight)
        drawLines(in: body)
        drawPeaks(in: body)
        drawSoundBar(in: body)
        drawRuler()
        drawPlayhead()
        drawStatus(in: body)
    }

    private func drawRuler() {
        let ruler = NSRect(x: 0, y: 0, width: bounds.width, height: Metrics.rulerHeight)
        NSColor.windowBackgroundColor.setFill()
        ruler.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: ruler.maxY - 1, width: ruler.width, height: 1).fill()

        let pointsPerSecond = waveform.pointsPerSecond
        let interval = Self.tickIntervals.first { $0 * pointsPerSecond >= Metrics.minimumTickSpacing } ?? Self.tickIntervals[Self.tickIntervals.count - 1]
        let firstTick = (waveform.visibleStart.seconds / interval).rounded(.down) * interval
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var seconds = firstTick
        while true {
            let x = CGFloat(waveform.x(of: AudioTime(seconds: seconds)))
            if x > bounds.width { break }
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: x, y: ruler.maxY - 5, width: 1, height: 4).fill()
            (Self.rulerLabel(seconds, interval: interval) as NSString).draw(at: NSPoint(x: x + 2, y: 1), withAttributes: attributes)
            seconds += interval
        }
    }

    private static func rulerLabel(_ seconds: Double, interval: Double) -> String {
        let minutes = Int(seconds) / 60
        let wholeSeconds = Int(seconds) % 60
        if interval < 1 {
            let tenths = Int((seconds * 10).rounded()) % 10
            return String(format: "%d:%02d.%d", minutes, wholeSeconds, tenths)
        }
        return String(format: "%d:%02d", minutes, wholeSeconds)
    }

    private func drawLines(in body: NSRect) {
        let lines = editor.displayedLines
        let selected = Set(editor.selection)
        let active = editor.activeIndex
        let visibleEnd = waveform.time(atX: width)
        let accent = NSColor.controlAccentColor
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        for (index, line) in lines.enumerated() where line.end >= waveform.visibleStart && line.start <= visibleEnd && index != active {
            let rect = self.rect(of: line, in: body)
            (selected.contains(index) ? accent.withAlphaComponent(0.12) : NSColor.quaternaryLabelColor.withAlphaComponent(0.25)).setFill()
            rect.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
            NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
            drawLabel(index: index, line: line, in: rect, attributes: labelAttributes)
        }

        guard let active, lines.indices.contains(active) else { return }
        let line = lines[active]
        let rect = self.rect(of: line, in: body)
        accent.withAlphaComponent(0.18).setFill()
        rect.fill()
        // Overlaps with other lines in red.
        NSColor.systemRed.withAlphaComponent(0.25).setFill()
        for other in SubtitleEditing.overlapping(active, in: lines) {
            let overlap = rect.intersection(self.rect(of: lines[other], in: body))
            if !overlap.isEmpty {
                overlap.fill()
            }
        }
        drawLabel(index: active, line: line, in: rect, attributes: labelAttributes)
        if editor.isEditable {
            for (x, isStart) in [(rect.minX, true), (rect.maxX, false)] {
                let isSnapped = snappedTime.map { CGFloat(waveform.x(of: $0)) == x } ?? false
                let handleWidth = isSnapped ? Metrics.snappedHandleWidth : Metrics.handleWidth
                accent.setFill()
                NSRect(x: x - handleWidth / 2, y: rect.minY, width: handleWidth, height: rect.height).fill()
                let tab = Metrics.grabTabSize
                NSRect(x: isStart ? x : x - tab.width, y: rect.minY, width: tab.width, height: tab.height).fill()
            }
        }
        if let dragLabel {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.controlBackgroundColor.withAlphaComponent(0.85),
            ]
            (dragLabel as NSString).draw(at: NSPoint(x: rect.minX + Metrics.labelInset, y: rect.maxY - 16), withAttributes: attributes)
        }
    }

    private func drawLabel(index: Int, line: TimedText, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let text = rect.width >= Metrics.minimumWidthForText
            ? "#\(index + 1) \(line.text.replacingOccurrences(of: "\n", with: " "))"
            : "#\(index + 1)"
        let labelRect = NSRect(x: rect.minX + Metrics.labelInset, y: rect.minY + Metrics.labelInset,
                               width: max(rect.width - 2 * Metrics.labelInset, 0), height: 14)
        (text as NSString).draw(with: labelRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attributes)
    }

    private func drawPeaks(in body: NSRect) {
        guard let summary = waveform.waveform else { return }
        let middle = body.midY
        let halfHeight = body.height / 2 - 2
        let path = NSBezierPath()
        var x: CGFloat = 0
        while x < bounds.width {
            let start = waveform.time(atX: Double(x))
            guard start < summary.duration else { break }
            let peak = CGFloat(summary.peak(from: start, to: waveform.time(atX: Double(x + 1))))
            let height = max(peak * halfHeight, 0.5)
            path.move(to: NSPoint(x: x + 0.5, y: middle - height))
            path.line(to: NSPoint(x: x + 0.5, y: middle + height))
            x += 1
        }
        NSColor.secondaryLabelColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawSoundBar(in body: NSRect) {
        NSColor.systemGreen.withAlphaComponent(0.5).setFill()
        let visibleEnd = waveform.time(atX: width)
        for span in waveform.snapSpans ?? [] where span.end >= waveform.visibleStart && span.start <= visibleEnd {
            let minX = CGFloat(waveform.x(of: span.start))
            let maxX = CGFloat(waveform.x(of: span.end))
            NSRect(x: minX, y: body.maxY - Metrics.soundBarHeight, width: maxX - minX, height: Metrics.soundBarHeight).fill()
        }
    }

    private func drawPlayhead() {
        let x = CGFloat(waveform.x(of: playheadTime))
        guard x >= 0, x <= bounds.width else { return }
        NSColor.systemRed.setFill()
        NSRect(x: x.rounded(.down), y: 0, width: 1, height: bounds.height).fill()
    }

    private func drawStatus(in body: NSRect) {
        let message: String? = if waveform.isLoading {
            String(localized: "Loading waveform…")
        } else {
            waveform.loadFailureMessage
        }
        guard let message else { return }
        if waveform.isLoading {
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: 0, y: body.midY, width: bounds.width, height: 1).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        (message as NSString).draw(at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height - Metrics.statusSpacing), withAttributes: attributes)
    }

    private func rect(of line: TimedText, in body: NSRect) -> NSRect {
        let minX = CGFloat(waveform.x(of: line.start))
        let maxX = CGFloat(waveform.x(of: line.end))
        return NSRect(x: minX, y: body.minY, width: max(maxX - minX, 1), height: body.height)
    }

    // MARK: Mouse

    /// What is under the pointer: an edge of the active line, or its body.
    private func hit(at point: NSPoint) -> (index: Int, edge: Bool?)? {
        guard editor.isEditable, point.y > Metrics.rulerHeight, let index = editor.activeIndex, let line = editor.activeLine else {
            return nil
        }
        let startX = CGFloat(waveform.x(of: line.start))
        let endX = CGFloat(waveform.x(of: line.end))
        if abs(point.x - startX) <= Metrics.handleHitWidth {
            return (index, true)
        }
        if abs(point.x - endX) <= Metrics.handleHitWidth {
            return (index, false)
        }
        return point.x > startX && point.x < endX ? (index, nil) : nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch hit(at: point) {
        case .some((_, .some)):
            NSCursor.resizeLeftRight.set()
        case .some((_, nil)):
            NSCursor.openHand.set()
        default:
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let time = waveform.time(atX: Double(point.x))
        let lineUnderPointer = point.y > Metrics.rulerHeight
            ? editor.displayedLines.indices.last { time >= editor.displayedLines[$0].start && time < editor.displayedLines[$0].end }
            : nil
        let isOnLabelStrip = point.y > Metrics.rulerHeight && point.y <= Metrics.rulerHeight + Metrics.labelStripHeight
        if let index = lineUnderPointer, index != editor.activeIndex, isOnLabelStrip || event.clickCount == 2 {
            onSelectLine(index)
            return
        }
        switch hit(at: point) {
        case .some((let index, .some(let isStart))):
            guard let line = editor.activeLine else { return }
            drag = .handle(index: index, isStart: isStart, fixed: isStart ? line.end : line.start)
        case .some((_, nil)):
            drag = .shift(grabbedAt: time, downX: point.x, isMoving: false)
        default:
            drag = .seeking
            seek(toX: point.x)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let drag else { return }
        autoscroll(for: point.x)
        let snaps = !event.modifierFlags.contains(.option)
        switch drag {
        case .seeking:
            seek(toX: point.x)
        case .handle(let index, let isStart, let fixed):
            var time = waveform.time(atX: Double(point.x))
            snappedTime = snaps ? snapTarget(near: time, excluding: index) : nil
            time = snappedTime ?? time
            // Never past the other edge: at least 1 ms long.
            let minimumLength = AudioTime(milliseconds: 1)
            time = isStart ? min(time, fixed - minimumLength) : max(time, fixed + minimumLength)
            time = max(time, .zero)
            let start = isStart ? time : fixed
            let end = isStart ? fixed : time
            editor.previewTimes(of: index, start: start, end: end, movesNeighbours: event.modifierFlags.contains(.shift))
            dragLabel = "\(SubtitleTimeFormat.string(isStart ? start : end))  (\(SubtitleTimeFormat.string(end - start)))"
        case .shift(let grabbedAt, let downX, let isMoving):
            guard isMoving || abs(point.x - downX) >= Metrics.dragThreshold else { return }
            if !isMoving {
                self.drag = .shift(grabbedAt: grabbedAt, downX: downX, isMoving: true)
                NSCursor.closedHand.set()
            }
            let offset = waveform.time(atX: Double(point.x)) - grabbedAt
            editor.previewShift(by: offset)
            dragLabel = (offset.samples >= 0 ? "+" : "−") + SubtitleTimeFormat.string(AudioTime(samples: abs(offset.samples)))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .handle:
            editor.commitTimingPreview(actionName: String(localized: "Change Times"))
        case .shift(_, _, isMoving: true):
            editor.commitTimingPreview(actionName: String(localized: "Shift Times"))
        case .shift(_, _, isMoving: false):
            seek(toX: point.x)
        default:
            break
        }
        drag = nil
        snappedTime = nil
        dragLabel = nil
        mouseMoved(with: event)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(SubtitleEditorMenu.make(), with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !event.modifierFlags.intersection([.command, .option]).isEmpty {
            let delta = event.scrollingDeltaY == 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            waveform.zoom(by: exp(Double(delta * Metrics.scrollZoomSensitivity)), anchorX: Double(point.x), width: width)
            return
        }
        // Either axis pans; vertical wheels are the common case.
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        waveform.scroll(byPoints: -Double(delta), width: width)
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        waveform.zoom(by: 1 + Double(event.magnification), anchorX: Double(point.x), width: width)
    }

    private func seek(toX x: CGFloat) {
        let time = min(max(waveform.time(atX: Double(x)), .zero), max(waveform.duration, .zero))
        playheadTime = time
        onSeek(time)
    }

    /// Pans while dragging near either edge.
    private func autoscroll(for x: CGFloat) {
        if x < Metrics.autoscrollMargin {
            waveform.scroll(byPoints: -Double(Metrics.autoscrollStep), width: width)
        } else if x > bounds.width - Metrics.autoscrollMargin {
            waveform.scroll(byPoints: Double(Metrics.autoscrollStep), width: width)
        }
    }

    /// The nearest line edge, playhead or speech boundary within 6 points.
    private func snapTarget(near time: AudioTime, excluding index: Int) -> AudioTime? {
        let threshold = AudioTime(seconds: Double(Metrics.snapDistance) / waveform.pointsPerSecond)
        let visibleEnd = waveform.time(atX: width)
        var candidates = [playheadTime]
        for (other, line) in editor.lines.enumerated() where other != index && line.end >= waveform.visibleStart && line.start <= visibleEnd {
            candidates += [line.start, line.end]
        }
        for span in waveform.snapSpans ?? [] where span.end >= waveform.visibleStart && span.start <= visibleEnd {
            candidates += [span.start, span.end]
        }
        let nearest = candidates.min { abs(($0 - time).samples) < abs(($1 - time).samples) }
        return nearest.flatMap { abs(($0 - time).samples) <= threshold.samples ? $0 : nil }
    }

    // MARK: Keyboard (Aegisub's audio display keys)

    /// The keys below and the modifiers of the drags and scrolls above, for
    /// the Shortcuts settings page; keep it in step with them.
    static var keyboardShortcuts: [KeyboardShortcut] {
        let drag = String(localized: "Drag")
        let scroll = String(localized: "Scroll")
        return SubtitleEditorMenu.playbackKeyShortcuts + [
            KeyboardShortcut(name: String(localized: "Select Previous Line"), keyEquivalent: String(NSEvent.SpecialKey.upArrow.unicodeScalar)),
            KeyboardShortcut(name: String(localized: "Select Next Line"), keyEquivalent: String(NSEvent.SpecialKey.downArrow.unicodeScalar)),
            KeyboardShortcut(name: String(localized: "Move Playhead Back 0.1 s"), keyEquivalent: String(NSEvent.SpecialKey.leftArrow.unicodeScalar)),
            KeyboardShortcut(name: String(localized: "Move Playhead Forward 0.1 s"), keyEquivalent: String(NSEvent.SpecialKey.rightArrow.unicodeScalar)),
            KeyboardShortcut(name: String(localized: "Move Playhead Back 1 s"), keyEquivalent: String(NSEvent.SpecialKey.leftArrow.unicodeScalar), modifiers: .shift),
            KeyboardShortcut(name: String(localized: "Move Playhead Forward 1 s"), keyEquivalent: String(NSEvent.SpecialKey.rightArrow.unicodeScalar), modifiers: .shift),
            KeyboardShortcut(name: String(localized: "Move an Edge with the Touching Line"), keyEquivalent: "", modifiers: .shift, gesture: drag),
            KeyboardShortcut(name: String(localized: "Move an Edge Without Snapping"), keyEquivalent: "", modifiers: .option, gesture: drag),
            KeyboardShortcut(name: String(localized: "Zoom"), keyEquivalent: "", modifiers: .option, gesture: scroll),
            KeyboardShortcut(name: String(localized: "Zoom"), keyEquivalent: "", modifiers: .command, gesture: scroll),
        ]
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        let step = event.modifierFlags.contains(.shift) ? Self.largeNudge : Self.nudge
        switch event.specialKey {
        case .upArrow?:
            NSApp.sendAction(#selector(SubtitleEditorCommands.selectPreviousLine(_:)), to: nil, from: self)
        case .downArrow?:
            NSApp.sendAction(#selector(SubtitleEditorCommands.selectNextLine(_:)), to: nil, from: self)
        case .leftArrow?:
            onSeek(max(playheadTime - step, .zero))
        case .rightArrow?:
            onSeek(playheadTime + step)
        case nil:
            if let action = event.charactersIgnoringModifiers.flatMap(SubtitleEditorMenu.playbackKeyAction(for:)) {
                NSApp.sendAction(action, to: nil, from: self)
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }
}
