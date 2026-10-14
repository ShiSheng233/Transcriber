#if DEBUG
import AppKit
import TranscriberCore

/// Development aid: `-RenderSnapshots <directory>` renders every settings tab
/// and the main window to PNG files, then quits. With `-SnapshotMedia <file>`
/// it first transcribes that file, selects it and also renders the Activity
/// window. Used
/// to review layouts without screen recording. Not compiled into release builds.
enum DebugSnapshotRenderer {
    static var requestedDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-RenderSnapshots"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static var requestedMedia: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-SnapshotMedia"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// Adds and runs `media`, waiting up to five minutes for it to finish.
    /// Renders `main-running.png` once the first chunk is done.
    static func transcribe(_ media: URL, with queueViewModel: JobQueueViewModel, main: MainWindowController, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        main.window?.appearance = NSAppearance(named: .aqua)
        // A copy in an empty folder: no subtitles beside it to ask about, and
        // the subtitle files the run writes stay out of the media folder.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriberSnapshot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(media.lastPathComponent)
        try? FileManager.default.copyItem(at: media, to: copy)
        queueViewModel.addFiles([copy])
        let deadline = Date().addingTimeInterval(300)
        while queueViewModel.jobs.isEmpty, Date() < deadline {
            if queueViewModel.pendingSubtitleChoice != nil {
                queueViewModel.resolveSubtitleChoice(.transcribe)  // never wait for a person
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        queueViewModel.select(jobID: queueViewModel.jobs.first?.id)
        queueViewModel.startQueue(usesLanguageModel: false)
        var renderedRunning = false
        while queueViewModel.jobs.contains(where: { !$0.status.isFinished }), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if !renderedRunning, case .transcribing(let completed, _)? = queueViewModel.jobs.first?.status, completed >= 1 {
                renderedRunning = true
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                snapshot(main.window?.contentView, to: directory.appendingPathComponent("main-running.png"))
            }
        }
        queueViewModel.select(jobID: queueViewModel.jobs.first?.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // -SnapshotTogglePlayer: one click on the Player button, as a user would.
        if ProcessInfo.processInfo.arguments.contains("-SnapshotTogglePlayer") {
            main.togglePlayer(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
    }

    static func renderActivity(_ activity: ActivityWindowController, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        activity.window?.appearance = NSAppearance(named: .aqua)
        activity.showWindow(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        snapshot(activity.window?.contentView, to: directory.appendingPathComponent("activity.png"))
    }

    static func render(settings: SettingsWindowController, main: MainWindowController, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Light mode only: cacheDisplay renders dark-mode views onto an opaque
        // white bitmap. The app uses semantic colors throughout.
        let light = NSAppearance(named: .aqua)
        settings.window?.appearance = light
        main.window?.appearance = light
        if let tabs = settings.window?.contentViewController as? NSTabViewController {
            tabs.transitionOptions = []  // the crossfade would capture an empty view
            for index in tabs.tabViewItems.indices {
                tabs.selectedTabViewItemIndex = index
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                let name = tabs.tabViewItems[index].label
                // The whole window content, as the user sees it in its tab.
                snapshot(settings.window?.contentView, to: directory.appendingPathComponent("settings-\(name).png"))
            }
        }
        snapshot(main.window?.contentView, to: directory.appendingPathComponent("main.png"))
    }

    private static func snapshot(_ view: NSView?, to url: URL) {
        guard let view, let appearance = view.window?.appearance else {
            return
        }
        // cacheDisplay draws with the current drawing appearance, not the window's.
        appearance.performAsCurrentDrawingAppearance {
            view.needsDisplay = true
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // Views are transparent; put them on the window background.
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            bitmap.draw(in: view.bounds)
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let composed = NSBitmapImageRep(data: tiff) {
                try? composed.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}
#endif
