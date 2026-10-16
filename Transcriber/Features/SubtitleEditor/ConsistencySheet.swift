import AppKit
import TranscriberCore

/// Check Consistency: every name or term the file writes in more than one
/// way, with how often each spelling occurs. The user picks the spelling to
/// keep for each and which to unify; Unify rewrites them as one undo step.
final class ConsistencySheet: EditorSheet {
    private static let listMaximumHeight: CGFloat = 320
    private static let listWidth: CGFloat = 420

    private let editor: SubtitleEditorViewModel
    private let glossaryTerms: () -> [String]
    private let list = NSStackView()
    private let scrollView = NSScrollView()
    private lazy var listHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
    private var groups: [TermVariants.Group] = []
    private var groupBoxes: [NSButton] = []
    private var spellingPopUps: [NSPopUpButton] = []
    /// The spellings that will be replaced, next to each group's choice.
    private var replacedLabels: [NSTextField] = []

    /// - Parameter glossaryTerms: names and terms with a known spelling, read each time the sheet opens.
    init(editor: SubtitleEditorViewModel, glossaryTerms: @escaping () -> [String]) {
        self.editor = editor
        self.glossaryTerms = glossaryTerms
        super.init(title: String(localized: "Check Consistency"), confirmTitle: String(localized: "Unify"))
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = list
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            list.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: Self.listWidth),
            listHeight,
        ])
        let explanation = NSTextField(wrappingLabelWithString: String(localized:
            "Names and terms written in more than one way: differing in width, case, hiragana or katakana, small kana, long vowel marks or middle dots. Glossary terms keep the glossary's spelling. Choose the spelling to keep and which terms to unify."
        ))
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = Self.listWidth
        form.addArrangedSubview(explanation)
        form.addArrangedSubview(scrollView)
    }

    /// Finds the groups again: the lines may have changed since the last time.
    override func begin(on window: NSWindow) {
        reload()
        super.begin(on: window)
    }

    private func reload() {
        groups = editor.termVariantGroups(glossaryTerms: glossaryTerms())
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        groupBoxes = []
        spellingPopUps = []
        replacedLabels = []
        for group in groups {
            let box = checkbox("")
            box.state = .on
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.target = self
            popUp.action = #selector(fieldChanged(_:))
            for spelling in group.spellings {
                let title = spelling.text == group.glossarySpelling
                    ? String(localized: "\(spelling.text)  ×\(spelling.count)  (glossary)")
                    : String(localized: "\(spelling.text)  ×\(spelling.count)")
                popUp.addItem(withTitle: title)
            }
            popUp.selectItem(at: group.spellings.firstIndex { $0.text == group.suggestedSpelling } ?? 0)
            let replacedLabel = NSTextField(labelWithString: "")
            replacedLabel.textColor = .secondaryLabelColor
            replacedLabel.lineBreakMode = .byTruncatingTail
            replacedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [box, popUp, replacedLabel])
            row.spacing = 6
            list.addArrangedSubview(row)
            groupBoxes.append(box)
            spellingPopUps.append(popUp)
            replacedLabels.append(replacedLabel)
        }
        if groups.isEmpty {
            list.addArrangedSubview(NSTextField(labelWithString: String(localized: "Every name and term is written one way.")))
        }
        list.layoutSubtreeIfNeeded()
        listHeight.constant = min(list.fittingSize.height, Self.listMaximumHeight)
    }

    /// The spelling to keep by group key, for the checked groups.
    private var chosenSpellings: [String: String] {
        var spellings: [String: String] = [:]
        for (index, group) in groups.enumerated() where groupBoxes[index].state == .on {
            let chosen = spellingPopUps[index].indexOfSelectedItem
            if group.spellings.indices.contains(chosen) {
                spellings[group.key] = group.spellings[chosen].text
            }
        }
        return spellings
    }

    override func update() {
        for (index, group) in groups.enumerated() {
            let kept = spellingPopUps[index].indexOfSelectedItem
            let replaced = group.spellings.enumerated().filter { $0.offset != kept && $0.element.count > 0 }.map(\.element.text)
            replacedLabels[index].stringValue = String(localized: "replaces \(replaced.joined(separator: ", "))")
        }
        let count = chosenSpellings.count
        summaryLabel.stringValue = groups.isEmpty ? "" : String(localized: "\(count) of \(groups.count) terms to unify")
        confirmButton.isEnabled = count > 0 && editor.isEditable
    }

    override func confirm() -> Bool {
        let spellings = chosenSpellings
        guard !spellings.isEmpty else {
            NSSound.beep()
            return false
        }
        editor.unifySpellings(spellings)
        return true
    }
}
