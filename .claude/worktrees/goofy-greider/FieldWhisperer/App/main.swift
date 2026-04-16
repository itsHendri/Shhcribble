import AppKit

// Top-level code in main.swift runs on the main thread.
// MainActor.assumeIsolated lets us instantiate @MainActor types synchronously.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
