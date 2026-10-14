#if DEBUG
import AppKit

/// Development aid: `-RenderSnapshots <directory>` renders every settings tab
/// and the main window to PNG files, then quits. Used
/// to review layouts without screen recording. Not compiled into release builds.
enum DebugSnapshotRenderer {
    static var requestedDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-RenderSnapshots"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
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
