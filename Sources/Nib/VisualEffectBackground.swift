import AppKit
import SwiftUI

/// Real vibrancy behind the window's content.
///
/// Taken from the desktop-card family rather than chess-coach: that app paints a
/// flat near-black fill, which means it has no light mode at all and every
/// foreground colour is white at some opacity. An NSVisualEffectView follows the
/// system appearance for free, which is what a .regular app with a Dock icon is
/// expected to do.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}
