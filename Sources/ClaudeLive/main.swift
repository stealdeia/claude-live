import AppKit

/// Retained for the whole process lifetime: `NSApplication.delegate` is a weak
/// reference, so a local would be deallocated immediately.
private var appDelegate: AppDelegate?

// Manual bootstrap rather than the SwiftUI `App` lifecycle: a menu-bar-only app
// with a non-activating panel needs direct control over NSApplication, and the
// SwiftUI scene machinery gets in the way of that.
//
// Top-level code in main.swift already runs on the main thread; `assumeIsolated`
// tells the compiler that instead of forcing everything through an async hop.
MainActor.assumeIsolated {
    let app = NSApplication.shared

    let delegate = AppDelegate()
    appDelegate = delegate
    app.delegate = delegate

    // Redundant with LSUIElement in Info.plist, but makes the app behave
    // correctly even when the binary is run straight out of .build.
    app.setActivationPolicy(.accessory)

    app.run()
}
