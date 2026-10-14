import AppKit
import UserNotifications

/// Shows the queue outside the window: a progress bar and a count of
/// remaining files on the Dock icon, and a notification when the queue
/// finishes while the app is in the background.
final class AppStatusPresenter {
    private let viewModel: ActivityViewModel
    private let progressBar = NSProgressIndicator()
    private let dockView: NSView
    private var binder: ObservationBinder?
    private var notifiedRun: ActivityViewModel.RunSummary?

    init(viewModel: ActivityViewModel) {
        self.viewModel = viewModel

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        dockView = NSView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        dockView.addSubview(iconView)
        dockView.addSubview(progressBar)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: dockView.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: dockView.bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: dockView.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: dockView.trailingAnchor),
            progressBar.leadingAnchor.constraint(equalTo: dockView.leadingAnchor, constant: 10),
            progressBar.trailingAnchor.constraint(equalTo: dockView.trailingAnchor, constant: -10),
            progressBar.bottomAnchor.constraint(equalTo: dockView.bottomAnchor, constant: -8),
        ])
        binder = ObservationBinder { [weak self] in self?.render() }
    }

    private func render() {
        let dockTile = NSApp.dockTile
        if let fraction = viewModel.queueFraction {
            progressBar.doubleValue = fraction
            dockView.frame = NSRect(origin: .zero, size: dockTile.size)
            dockTile.contentView = dockView
            dockTile.badgeLabel = viewModel.remainingFileCount > 1 ? "\(viewModel.remainingFileCount)" : nil
        } else {
            dockTile.contentView = nil
            dockTile.badgeLabel = nil
        }
        dockTile.display()

        if let run = viewModel.finishedRun, run != notifiedRun {
            notifiedRun = run
            notify(run)
        }
    }

    private func notify(_ run: ActivityViewModel.RunSummary) {
        guard !NSApp.isActive, run.completed + run.failed > 0 else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = run.failed == 0 ? String(localized: "Subtitles Ready") : String(localized: "Transcription Finished")
        content.body = run.failed == 0
            ? String(localized: "\(run.completed) files done.")
            : String(localized: "\(run.completed) done, \(run.failed) failed.")
        content.sound = .default
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                return
            }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
