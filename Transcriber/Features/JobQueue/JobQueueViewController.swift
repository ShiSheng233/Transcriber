import AppKit

/// Placeholder for the job queue. Gets its view model in Phase 2.
final class JobQueueViewController: NSViewController {
    override func loadView() {
        let placeholder = NSTextField(labelWithString: "Drop audio or video files here")
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])
        view = container
    }
}
