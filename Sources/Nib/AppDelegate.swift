import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow?
    /// Filled once the daemon reports which looks it can render. Kept as fields
    /// because the menu bar is built at launch and the answer arrives later.
    private let lookPNGMenu = NSMenu(title: "Export PNG with a Look")
    private let lookGIFMenu = NSMenu(title: "Export GIF with a Look")
    private let recolourMenu = NSMenu(title: "Recolour Canvas")
    private let rollStepMenu = NSMenu(title: "Roll Step")
    private var previewWindow: NSWindow?
    private let store = CanvasStore()
    /// A file LaunchServices handed over before the window existed.
    private var launchFile: URL?
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()

        let root = RootView().environmentObject(store)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WindowSize.width, height: WindowSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Nib"
        w.contentView = NSHostingView(rootView: root)
        // Genuinely resizable, with a floor rather than a pinned frame: the
        // canvas grows with the window and only the controls column is fixed.
        w.minSize = NSSize(width: WindowSize.minWidth, height: WindowSize.minHeight)
        w.center()
        w.setFrameAutosaveName("Nib.mainWindow")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        window = w
        store.window = w

        Task { await store.loadLooks(); populateLookMenus() }
        Task { await store.loadEffects() }
        AppLink.shared.start(store: store)
        NSApp.activate(ignoringOtherApps: true)

        // A file you opened Nib with wins; otherwise pick up where the last
        // session left off, which is the whole reason saving exists.
        launched = true
        if let url = launchFile {
            store.openAny(url)
        } else if !openLaunchArgument() {
            _ = store.restoreLastProject()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Never close over unsaved work without asking. The app has one window, so
    /// closing it is quitting, and there is no document system to do this for us.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.confirmDiscard() else { return .terminateCancel }
        AppLink.shared.stop()
        return .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { store.confirmDiscard() }

    /// Files dropped on the Dock icon, double-clicked, or `open -a Nib file`.
    /// At launch this arrives *before* `applicationDidFinishLaunching`, which
    /// used to open the file and then immediately replace it with the last
    /// project. So at launch it is held until the window exists.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if launched { store.openAny(url) } else { launchFile = url }
    }

    /// `Nib drawing.png` or `Nib sprite.nibart`, for `swift run`: a bare
    /// executable has no bundle, so LaunchServices cannot route a file to it.
    @discardableResult
    private func openLaunchArgument() -> Bool {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") })
        else { return false }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        store.openAny(url)
        return true
    }

    // MARK: - Menu

    /// A .regular app gets no menu bar for free, and without one Cmd+Q, Cmd+W and
    /// Cmd+O simply do not work. chess-coach shipped without this and inherited
    /// the gap from the card family, which has no menu because it is not an app.
    private func installMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Nib", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Nib", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Nib", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New", action: #selector(newProject), keyEquivalent: "n")
        // One Open for both kinds of file, routed by extension. Two items that
        // both say "open" is the sort of thing that makes you pick the wrong one.
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Open Starts In…", action: #selector(chooseOpenFolder), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument), keyEquivalent: "s")
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(saveDocumentAs), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Export PNG", action: #selector(exportPNG), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Export GIF", action: #selector(exportGIF), keyEquivalent: "")
        let again = NSMenuItem(title: "Export Again", action: #selector(exportAgain), keyEquivalent: "e")
        again.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(again)

        fileMenu.addItem(withTitle: "Reveal Last Export", action: #selector(revealExports), keyEquivalent: "e")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(undoEdit), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(redoEdit), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(cut), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(copySelection), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(paste), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(selectAll), keyEquivalent: "a")
        editMenu.addItem(withTitle: "Clear Selection", action: #selector(clearSelection), keyEquivalent: "\u{8}")
        editMenu.addItem(.separator())
        // Selection if there is one, else the whole cel, active layer only.
        for (title, key, mods, sel) in [
            ("Flip Horizontal",        "h", NSEvent.ModifierFlags([.command, .shift]), #selector(flipH)),
            ("Flip Vertical",          "v", NSEvent.ModifierFlags([.command, .shift]), #selector(flipV)),
            ("Rotate Clockwise",       "]", NSEvent.ModifierFlags([.command]),         #selector(rotateCW)),
            ("Rotate Anticlockwise",   "[", NSEvent.ModifierFlags([.command]),         #selector(rotateCCW)),
        ] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            editMenu.addItem(item)
        }
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Revert to Chosen Option", action: #selector(revertEdits), keyEquivalent: "r")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Show Grid", action: #selector(toggleGrid), keyEquivalent: "'")
        viewMenu.addItem(withTitle: "Tile Preview", action: #selector(toggleTiling), keyEquivalent: "t")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let frameItem = NSMenuItem()
        let frameMenu = NSMenu(title: "Frame")
        frameMenu.addItem(withTitle: "Add Frame", action: #selector(addFrame), keyEquivalent: "")
        let dup = NSMenuItem(title: "Duplicate Frame", action: #selector(duplicateFrame), keyEquivalent: "d")
        frameMenu.addItem(dup)
        // Shifted, because plain Cmd+C/V belong to the cells you have selected.
        for (title, key, sel) in [("Copy Frame", "c", #selector(copyFrame)),
                                  ("Paste Frame", "v", #selector(pasteFrame))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .shift]
            frameMenu.addItem(item)
        }
        frameMenu.addItem(withTitle: "Delete Frame", action: #selector(deleteFrame), keyEquivalent: "")
        frameMenu.addItem(.separator())
        let prev = NSMenuItem(title: "Previous Frame", action: #selector(previousFrame), keyEquivalent: ",")
        let next = NSMenuItem(title: "Next Frame", action: #selector(nextFrame), keyEquivalent: ".")
        frameMenu.addItem(prev)
        frameMenu.addItem(next)
        for (title, key, sel) in [
            ("Move Frame Earlier", NSLeftArrowFunctionKey,  #selector(frameEarlier)),
            ("Move Frame Later",   NSRightArrowFunctionKey, #selector(frameLater)),
        ] {
            let item = NSMenuItem(title: title, action: sel,
                                  keyEquivalent: String(UnicodeScalar(UInt32(key))!))
            item.keyEquivalentModifierMask = [.command, .shift]
            frameMenu.addItem(item)
        }
        frameMenu.addItem(.separator())
        // Option-arrow rolls the frame with wrap-around. Plain arrows are left
        // alone: the canvas sits in a scroll view at anything above Fit.
        for (title, key, sel) in [
            ("Roll Left",  NSLeftArrowFunctionKey,  #selector(rollLeft)),
            ("Roll Right", NSRightArrowFunctionKey, #selector(rollRight)),
            ("Roll Up",    NSUpArrowFunctionKey,    #selector(rollUp)),
            ("Roll Down",  NSDownArrowFunctionKey,  #selector(rollDown)),
        ] {
            let item = NSMenuItem(title: title, action: sel,
                                  keyEquivalent: String(UnicodeScalar(UInt32(key))!))
            item.keyEquivalentModifierMask = [.option]
            frameMenu.addItem(item)
        }
        // How far one press rolls, next to the presses themselves. It used to be
        // reachable only inside the scrolling-run sheet, so nudging a single
        // frame by four cells meant opening a dialog about animation.
        let stepItem = NSMenuItem(title: "Roll Step", action: nil, keyEquivalent: "")
        for n in 1...8 {
            let item = NSMenuItem(title: n == 1 ? "1 cell" : "\(n) cells",
                                  action: #selector(setRollStep(_:)), keyEquivalent: "")
            item.representedObject = n
            item.target = self
            rollStepMenu.addItem(item)
        }
        stepItem.submenu = rollStepMenu
        frameMenu.addItem(stepItem)
        // Named for what it does to the picture, not for the noun it produces:
        // it sat directly under the Roll commands and still read as unrelated.
        frameMenu.addItem(withTitle: "Roll Across Frames…", action: #selector(buildScroll), keyEquivalent: "")
        frameMenu.addItem(.separator())
        frameMenu.addItem(withTitle: "Play / Stop", action: #selector(togglePlay), keyEquivalent: " ")
        frameItem.submenu = frameMenu
        main.addItem(frameItem)

        let layerItem = NSMenuItem()
        let layerMenu = NSMenu(title: "Layer")
        let addL = NSMenuItem(title: "Add Layer", action: #selector(addLayer), keyEquivalent: "n")
        addL.keyEquivalentModifierMask = [.command, .shift]
        layerMenu.addItem(addL)
        layerMenu.addItem(withTitle: "Delete Layer", action: #selector(deleteLayer), keyEquivalent: "")
        layerMenu.addItem(.separator())
        for (title, key, sel) in [
            ("Move Layer Up",   NSUpArrowFunctionKey,   #selector(layerUp)),
            ("Move Layer Down", NSDownArrowFunctionKey, #selector(layerDown)),
        ] {
            let item = NSMenuItem(title: title, action: sel,
                                  keyEquivalent: String(UnicodeScalar(UInt32(key))!))
            item.keyEquivalentModifierMask = [.command, .shift]
            layerMenu.addItem(item)
        }
        layerMenu.addItem(.separator())
        layerMenu.addItem(withTitle: "Hide / Show Layer", action: #selector(toggleLayer), keyEquivalent: "")
        layerItem.submenu = layerMenu
        main.addItem(layerItem)

        // Everything decorated lives together. File keeps the clean exports, so a
        // decorated one is never a slip of the hand away from a plain one.
        let lookItem = NSMenuItem()
        let lookMenu = NSMenu(title: "Look")
        lookMenu.addItem(withTitle: "Show Look Preview", action: #selector(toggleLookPreview),
                         keyEquivalent: "l")
        lookMenu.addItem(.separator())
        let recolour = NSMenuItem(title: "Recolour Canvas", action: nil, keyEquivalent: "")
        recolour.submenu = recolourMenu
        lookMenu.addItem(recolour)
        lookMenu.addItem(.separator())
        let pngLooks = NSMenuItem(title: "Export PNG with a Look", action: nil, keyEquivalent: "")
        pngLooks.submenu = lookPNGMenu
        lookMenu.addItem(pngLooks)
        let gifLooks = NSMenuItem(title: "Export GIF with a Look", action: nil, keyEquivalent: "")
        gifLooks.submenu = lookGIFMenu
        lookMenu.addItem(gifLooks)
        lookItem.submenu = lookMenu
        main.addItem(lookItem)

        NSApp.mainMenu = main
    }

    @objc private func newProject() { store.newDocument() }
    @objc private func openDocument() { store.chooseFile() }
    @objc private func chooseOpenFolder() { store.chooseOpenFolder() }
    @objc private func saveDocument() { store.save() }
    @objc private func saveDocumentAs() { store.saveAs() }
    /// One item per look, in both submenus. Built after the daemon answers,
    /// because the list of looks belongs to it -- the app should not carry a
    /// second copy of what `nibd` can render.
    private func populateLookMenus() {
        recolourMenu.removeAllItems()
        for look in store.looks where look.filtered && look.id != "screen" {
            let item = NSMenuItem(title: look.name, action: #selector(recolourTo(_:)),
                                  keyEquivalent: "")
            item.representedObject = look.id
            item.target = self
            recolourMenu.addItem(item)
        }
        for (menu, isGIF) in [(lookPNGMenu, false), (lookGIFMenu, true)] {
            menu.removeAllItems()
            let filtered = store.looks.filter { $0.filtered }
            if filtered.isEmpty {
                let none = NSMenuItem(title: "No looks available", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
                continue
            }
            for look in filtered {
                let item = NSMenuItem(title: look.name,
                                      action: isGIF ? #selector(exportGIFLook(_:))
                                                    : #selector(exportPNGLook(_:)),
                                      keyEquivalent: "")
                item.representedObject = look.id
                item.target = self
                menu.addItem(item)
            }
        }
    }

    @objc private func recolourTo(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.recolour(to: id)
    }

    @objc private func toggleLookPreview() {
        if let w = previewWindow, w.isVisible { w.close(); return }
        let w = previewWindow ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow],
                             backing: .buffered, defer: false)
            w.title = "Look"
            w.contentView = NSHostingView(rootView: LookPreview().environmentObject(store))
            w.setFrameAutosaveName("Nib.lookPreview")
            w.isReleasedWhenClosed = false
            previewWindow = w
            return w
        }()
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func exportPNGLook(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.export(scale: 16, look: id)
    }

    @objc private func exportGIFLook(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.exportGIF(scale: 8, look: id)
    }

    @objc private func exportPNG() { store.export() }
    @objc private func exportGIF() { store.exportGIF() }
    @objc private func exportAgain() { store.exportAgain() }
    @objc private func toggleGrid() { store.showGrid.toggle() }
    @objc private func toggleTiling() { store.tiling.toggle() }

    /// Only here to tick the View toggles; everything else stays enabled as before.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleGrid) { item.state = store.showGrid ? .on : .off }
        if item.action == #selector(toggleTiling) { item.state = store.tiling ? .on : .off }
        // Greyed until something has been copied, so the menu says whether
        // there is a frame waiting rather than doing nothing when you pick it.
        if item.action == #selector(pasteFrame) { return store.canPasteFrame }
        if item.action == #selector(setRollStep(_:)) {
            item.state = (item.representedObject as? Int) == store.rollStep ? .on : .off
        }
        return true
    }
    @objc private func flipH() { store.transform(.flipH) }
    @objc private func flipV() { store.transform(.flipV) }
    @objc private func rotateCW() { store.transform(.rotateCW) }
    @objc private func rotateCCW() { store.transform(.rotateCCW) }

    @objc private func undoEdit() { store.undo() }
    @objc private func redoEdit() { store.redo() }
    @objc private func cut() { store.cutSelection() }
    @objc private func copySelection() { store.copySelection() }
    @objc private func paste() { store.paste() }
    @objc private func selectAll() { store.selectAll() }
    @objc private func clearSelection() { store.clearSelection() }
    @objc private func revertEdits() { store.revertToPicked() }

    @objc private func addFrame() { store.addFrame() }
    @objc private func duplicateFrame() { store.duplicateFrame() }
    @objc private func copyFrame() { store.copyFrame() }
    @objc private func pasteFrame() { store.pasteFrame() }
    @objc private func deleteFrame() { store.deleteFrame() }
    @objc private func previousFrame() { store.selectFrame(store.currentFrame - 1) }
    @objc private func nextFrame() { store.selectFrame(store.currentFrame + 1) }
    @objc private func togglePlay() { store.togglePlay() }
    @objc private func frameEarlier() { store.moveFrame(by: -1) }
    @objc private func frameLater() { store.moveFrame(by: 1) }
    @objc private func rollLeft() { store.roll(.left) }
    @objc private func rollRight() { store.roll(.right) }
    @objc private func rollUp() { store.roll(.up) }
    @objc private func rollDown() { store.roll(.down) }
    @objc private func buildScroll() { store.showingScrollBuilder = true }
    @objc private func setRollStep(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? Int else { return }
        store.rollStep = n
    }
    @objc private func addLayer() { store.addLayer() }
    @objc private func deleteLayer() { store.deleteLayer() }
    @objc private func layerUp() { store.moveLayer(by: 1) }
    @objc private func layerDown() { store.moveLayer(by: -1) }
    @objc private func toggleLayer() { store.toggleLayerVisible(store.currentLayer) }

    /// Exports now go wherever you put them, so reveal the actual file rather
    /// than a folder it probably is not in any more.
    @objc private func revealExports() {
        if let last = store.lastExport, FileManager.default.fileExists(atPath: last.path) {
            NSWorkspace.shared.activateFileViewerSelecting([last])
            return
        }
        try? FileManager.default.createDirectory(at: Paths.output, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Paths.output.path)
    }
}
