import AppKit

/// The save panel for an export, with a resolution picker in its accessory view.
///
/// Resolution belongs here rather than in the menu. It is a property of the file
/// you are about to write, decided at the moment you write it -- and as separate
/// menu items it meant `Export PNG` silently produced a 48x48 postage stamp
/// while the only larger option lived in a panel section that later got cut.
enum ExportPanel {

    /// Integer multiples only. Nearest-neighbour at a fractional scale makes
    /// some cells a pixel wider than their neighbours, which is the one thing
    /// pixel art must never do.
    static func scales(upTo limit: Int = 32) -> [Int] {
        [1, 2, 4, 8, 16, 32].filter { $0 <= limit }
    }

    /// Returns nil if cancelled.
    static func run(base: String, suffix: String, ext: String, kind: String,
                    gridSize: Int, directory: URL?,
                    scales: [Int], initial: Int) -> (url: URL, scale: Int)? {
        let panel = NSSavePanel()
        panel.prompt = "Export"
        panel.message = "Export \(kind)"
        // Show the extension: hiding it is how "Save As: Chester" ends up
        // telling you nothing about what you are getting.
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = false
        if let directory { panel.directoryURL = directory }

        let popup = NSPopUpButton(frame: NSRect(x: 54, y: 10, width: 200, height: 25))
        for s in scales {
            popup.addItem(withTitle: s == 1 ? "1× — \(gridSize)px (native)"
                                            : "\(s)× — \(gridSize * s)px")
        }
        popup.selectItem(at: scales.firstIndex(of: initial) ?? 0)

        let label = NSTextField(labelWithString: "Size:")
        label.frame = NSRect(x: 0, y: 14, width: 48, height: 17)
        label.alignment = .right

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 45))
        accessory.addSubview(label)
        accessory.addSubview(popup)
        panel.accessoryView = accessory

        func name(_ scale: Int) -> String {
            var n = "\(base)_\(gridSize)x\(gridSize)"
            if scale != 1 { n += "@\(scale)x" }
            return n + suffix + "." + ext
        }
        // The filename follows the picker, so what you are about to write is
        // never a surprise.
        let handler = Handler { panel.nameFieldStringValue = name(scales[popup.indexOfSelectedItem]) }
        popup.target = handler
        popup.action = #selector(Handler.fire)
        panel.nameFieldStringValue = name(initial)

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, scales[popup.indexOfSelectedItem])
    }

    /// Lives only for the duration of `runModal`, which is synchronous.
    private final class Handler: NSObject {
        private let block: () -> Void
        init(_ block: @escaping () -> Void) { self.block = block }
        @objc func fire() { block() }
    }
}
