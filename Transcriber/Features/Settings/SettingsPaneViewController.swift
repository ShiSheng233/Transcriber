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

    private var form: NSView?

    /// The form uses Auto Layout inside; it hangs from the top of a plain
    /// container, so it never stretches while the window changes height.
    override func loadView() {
        let form = makeForm()
        form.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: container.topAnchor),
            form.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            form.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        self.form = form
        view = container
    }

    /// Finish an edit in progress (Base URL, model, language…) before the
    /// pane goes away: closing the window does not end editing by itself.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        view.window?.makeFirstResponder(nil)
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

    /// Only a real change of the form's size resizes the window.
    private func fitWindowToForm() {
        guard let form else {
            return
        }
        form.layoutSubtreeIfNeeded()
        let size = form.fittingSize
        if abs(size.height - preferredContentSize.height) > 0.5 || abs(size.width - preferredContentSize.width) > 0.5 {
            preferredContentSize = size
        }
    }
}
