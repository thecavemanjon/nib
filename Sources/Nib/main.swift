import AppKit

// No @main / WindowGroup: this family builds NSApplication by hand so the
// activation policy and the single window are explicit rather than inferred.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // .regular, not .accessory: Nib is its own app with a Dock icon and a real
    // resizable window. It is not a desktop card.
    app.setActivationPolicy(.regular)
    app.run()
}
