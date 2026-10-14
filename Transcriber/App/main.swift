import AppKit

// AppKit lifecycle without a storyboard: create the delegate ourselves and
// keep it alive for the whole run (NSApplication.delegate is weak).
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
