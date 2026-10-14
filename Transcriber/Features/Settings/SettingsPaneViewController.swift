import AppKit

/// Shared behavior of the settings tabs: build the form once, redraw it from
/// the view model, and size the window to the form.
class SettingsPaneViewController: NSViewController {
    let viewModel: SettingsViewModel
    private var binder: ObservationBinder?

    init(viewModel: SettingsViewModel, title: String) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Settings panes are created in code")
    }

    override func loadView() {
        view = makeForm()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        binder = ObservationBinder { [weak self] in
            self?.render()
            self?.fitWindowToForm()
        }
    }

    /// Subclasses build their form with `SettingsForm`.
    func makeForm() -> NSView {
        NSView()
    }

    /// Subclasses copy the settings into their controls.
    func render() {}

    private func fitWindowToForm() {
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }
}
