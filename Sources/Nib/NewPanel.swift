import AppKit

/// Asks for a canvas size. `⌘N` used to hardcode 48x48, so the only way to a
/// blank 64 was importing a blank 64 PNG.
enum NewPanel {

    /// Returns nil if cancelled.
    static func run(sizes: [Int], initial: Int) -> Int? {
        let alert = NSAlert()
        alert.messageText = "New Canvas"
        alert.informativeText = "Pick a size. It can't be changed afterwards."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 25))
        for s in sizes { popup.addItem(withTitle: "\(s) × \(s)") }
        popup.selectItem(at: sizes.firstIndex(of: initial) ?? 0)
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return sizes[popup.indexOfSelectedItem]
    }
}
