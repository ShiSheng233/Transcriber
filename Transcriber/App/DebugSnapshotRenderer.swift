#if DEBUG
import AppKit
import LLMTranslation
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
        queueViewModel.addFiles([media])
        let deadline = Date().addingTimeInterval(300)
        while queueViewModel.jobs.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        queueViewModel.select(jobID: queueViewModel.jobs.first?.id)
        queueViewModel.startQueue()
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

    /// -KeyEntryCheck: types a test Base URL and key into the LLM pane the way
    /// a user does (focus moves field to field) and prints what the Keychain
    /// holds for the test host afterwards. Restores the previous Base URL.
    static func checkKeyEntry(settings: SettingsWindowController, keys: APIKeyStore, store: SettingsStore) {
        guard ProcessInfo.processInfo.arguments.contains("-KeyEntryCheck"),
              let window = settings.window, let tabs = window.contentViewController as? NSTabViewController,
              let llmIndex = tabs.tabViewItems.firstIndex(where: { $0.label == "LLM" }) else {
            return
        }
        let previousURL = store.settings.llm.baseURL
        tabs.selectedTabViewItemIndex = llmIndex
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let fields = allSubviews(of: window.contentView).compactMap { $0 as? NSTextField }
        guard let urlField = fields.first(where: { $0.placeholderString == "https://example.com/v1" }),
              let keyField = fields.first(where: { $0 is NSSecureTextField }) else {
            print("KEYCHECK fields not found")
            return
        }
        // Choosing "Custom" should put the cursor in the Base URL field.
        if let providerPopUp = allSubviews(of: window.contentView).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains("Custom") }) {
            providerPopUp.selectItem(withTitle: "Custom")
            _ = providerPopUp.target?.perform(providerPopUp.action, with: providerPopUp)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let editor = window.firstResponder
            print("KEYCHECK after Custom: editing URL field = \(editor === urlField.currentEditor()), editing key field = \(editor === keyField.currentEditor()), popup shows \(providerPopUp.titleOfSelectedItem ?? "")")
        }
        let testURL = "https://keycheck.example/v1"
        type(testURL, into: urlField, window: window)
        window.selectNextKeyView(nil)  // Tab, as a user would
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        print("KEYCHECK after Tab: first responder is key field = \(window.firstResponder === keyField.currentEditor())")
        type("sk-test-123", into: keyField, window: window)
        window.makeFirstResponder(nil)  // end editing
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let testBaseURL = URL(string: testURL)!
        print("KEYCHECK stored for test host: \(keys.read(for: testBaseURL))")
        // Paste a new key, then switch tabs and close the window without Return.
        type("sk-changed-456", into: keyField, window: window)
        tabs.selectedTabViewItemIndex = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        print("KEYCHECK after switching tabs: \(keys.read(for: testBaseURL))")
        tabs.selectedTabViewItemIndex = llmIndex
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        type("sk-closed-789", into: keyField, window: window)
        window.performClose(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        print("KEYCHECK after closing the window: \(keys.read(for: testBaseURL))")
        window.makeKeyAndOrderFront(nil)
        print("KEYCHECK base URL setting: \(store.settings.llm.baseURL.absoluteString)")
        keys.save("", for: testBaseURL)
        store.update { $0.llm.baseURL = previousURL }
    }

    private static func type(_ text: String, into field: NSTextField, window: NSWindow) {
        window.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.selectAll(nil)
        (field.currentEditor() as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private static func allSubviews(of view: NSView?) -> [NSView] {
        guard let view else {
            return []
        }
        return [view] + view.subviews.flatMap { allSubviews(of: $0) }
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
