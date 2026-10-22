import AppKit
import SwiftUI

@MainActor
final class CanvasStore: ObservableObject {
    // MARK: - Source and project

    @Published var sourceURL: URL?
    @Published var sourceSize: CGSize?
    /// Where this project was last saved. Nil until the first Save As.
    @Published var projectURL: URL? { didSet { retitle() } }
    /// Changed since the last save. Drives the title-bar dot and the quit guard.
    /// Distinct from `hasEdits`, which is "changed since an option was picked"
    /// and answers a different question: whether replacing the canvas costs work.
    @Published var isDirty = false { didSet { retitle() } }
    /// Bumped by every change to the canvas, including undo. Only meaningful
    /// within a run: the live link hands it out with the document and takes it
    /// back with the edit, so an edit computed from a canvas that has since
    /// moved on can be refused instead of quietly burying what was drawn in
    /// between. See `applyExternal`.
    @Published private(set) var documentVersion = 0
    /// The window, so the title and its modified dot can follow the document.
    weak var window: NSWindow?

    // MARK: - Import controls
    //
    // These describe the import, not the canvas, and are only on screen while
    // the spread is. Changing one rebuilds the spread.

    @Published var gridSize: Int = 48 { didSet { controlChanged() } }
    @Published var palette: Palette = Palettes.mono { didSet { paletteChanged(from: oldValue) } }
    /// The square of the source that gets reduced, as [left, top, side] in
    /// source pixels. Nil until the daemon proposes its default (tight round a
    /// doodle, the largest centred square otherwise); after that it is the
    /// frame the person drags on the original in the picker.
    @Published var crop: [Int]?
    /// The source's size in pixels, as the daemon read it. The crop tool's
    /// coordinates are in these, not in NSImage points, which can differ.
    @Published var sourcePixels: CGSize?

    // MARK: - The animation

    @Published var frames: [Frame] = [] { didSet { recount() } }
    @Published var currentFrame: Int = 0 { didSet { recount() } }
    /// Bottom first, so compositing is a forward loop. The timeline reverses it
    /// for display, because people expect the top layer at the top.
    @Published var layers: [LayerInfo] = [LayerInfo(name: "Layer 1")]
    @Published var currentLayer: Int = 0 { didSet { recount() } }
    @Published var fps: Double = 8
    @Published var onionSkin = false
    /// Frames shown either side, 1 to 3. Remembered: it is a working habit, not
    /// a property of any one drawing.
    @Published var onionRange: Int = max(1, UserDefaults.standard.integer(forKey: "Nib.onionRange")) {
        didSet { UserDefaults.standard.set(onionRange, forKey: "Nib.onionRange") }
    }
    /// Not remembered: it shrinks the canvas to a third, and finding it still
    /// on next launch would read as the canvas having broken.
    @Published var tiling = false
    @Published var showGrid = UserDefaults.standard.bool(forKey: "Nib.showGrid") {
        didSet { UserDefaults.standard.set(showGrid, forKey: "Nib.showGrid") }
    }
    @Published var isPlaying = false
    private var playTask: Task<Void, Never>?

    // Rolling. The direction is armed separately from the act of rolling: an
    // arrow that both selects and mutates means you cannot find out what it does
    // without changing your picture, which is how an original got lost.
    @Published var rollDirection: RollDirection = .down
    @Published var rollStep: Int = 1
    @Published var rollFrames: Int = 4
    @Published var rollMode: RollMode = .backAndForth
    /// The scrolling-run builder. A sheet rather than five permanent controls in
    /// the panel: you configure it once every few minutes, not continuously.
    @Published var showingScrollBuilder = false

    enum RollDirection: String, CaseIterable, Identifiable {
        case left, up, down, right
        var id: String { rawValue }
        var label: String { rawValue }
        var symbol: String {
            switch self {
            case .left: return "arrow.left"
            case .up: return "arrow.up"
            case .down: return "arrow.down"
            case .right: return "arrow.right"
            }
        }
        var delta: (dx: Int, dy: Int) {
            switch self {
            case .left:  return (-1, 0)
            case .up:    return (0, -1)
            case .down:  return (0, 1)
            case .right: return (1, 0)
            }
        }
    }

    enum RollMode: String, CaseIterable, Identifiable {
        /// Keeps going the same way. Seamless only when the frames carry the
        /// picture exactly once round: frames x step == grid size.
        case loop
        /// Out and back, a triangle. Two frames is a twitch, six is a sway, and
        /// it loops at any count without having to divide into the grid.
        case backAndForth
        var id: String { rawValue }
        var label: String { self == .loop ? "Keep going" : "Back and forth" }
    }

    /// The cel being edited: this frame, this layer. Every tool writes here.
    var grid: [[Int]] {
        get { hasCel ? frames[currentFrame].cels[currentLayer] : [] }
        set {
            guard hasCel else { return }
            frames[currentFrame].cels[currentLayer] = newValue
        }
    }

    private var hasCel: Bool {
        frames.indices.contains(currentFrame)
            && frames[currentFrame].cels.indices.contains(currentLayer)
    }

    /// What is actually on screen: every visible layer flattened. The canvas,
    /// the exports and the onion skin all show this; the tools all write to the
    /// cel above. That split is the whole of what layers are.
    var visible: [[Int]] {
        frames.indices.contains(currentFrame)
            ? frames[currentFrame].composite(layers) : []
    }

    func composite(_ i: Int) -> [[Int]] {
        frames.indices.contains(i) ? frames[i].composite(layers) : []
    }

    /// The grid size, taken from the frame rather than the active cel so it
    /// survives an empty layer.
    var size: Int { frames.indices.contains(currentFrame) ? (frames[currentFrame].cels.first?.count ?? 0) : 0 }
    var isEmpty: Bool { frames.isEmpty || size == 0 }

    @Published var usage: [Int: Int] = [:]

    // MARK: - Editing

    @Published var tool: Tool = .paint { didSet { if !tool.selects { selection = nil } } }
    @Published var selectedIndex: Int = 1
    /// Cells per screen point. 0 means fit the window.
    @Published var zoom: Double = 0
    /// Rectangle and ellipse draw an outline unless this is on.
    @Published var fillShapes = false
    @Published var symmetry: Symmetry = .off

    /// Cells a shape tool would stamp if the drag ended now. Drawn by the canvas
    /// and committed on release, from the same call, so what you saw is what you get.
    @Published private(set) var preview: Set<Cell> = []
    /// The selection's bounding box. Everything that predates the lasso reads
    /// only this, which is why a mask was added beside it rather than replacing it.
    @Published var selection: CellRect? { didSet { if selection == nil { selectionMask = nil } } }
    /// The cells actually selected, for a lasso. Nil means all of `selection`.
    @Published var selectionMask: Set<Cell>?

    func isSelected(_ c: Cell) -> Bool {
        guard let s = selection, s.contains(c) else { return false }
        return selectionMask?.contains(c) ?? true
    }

    /// Set both halves at once. A mask always travels with its own bounds.
    private func select(_ mask: Set<Cell>?, rect: CellRect?) {
        selection = rect
        selectionMask = mask
    }

    private var clipboard: [[Int]]?
    var canPaste: Bool { clipboard != nil }
    /// A whole frame, every layer of it. Separate from the cell clipboard
    /// because pasting cells and pasting a frame are different acts, and
    /// sharing one would mean copying a frame silently lost your selection.
    private var frameClipboard: Frame?
    var canPasteFrame: Bool { frameClipboard != nil }

    enum Tool: String, CaseIterable, Identifiable {
        case paint, fill, pick, line, rect, ellipse, select, lasso
        var id: String { rawValue }
        var selects: Bool { self == .select || self == .lasso }

        var label: String {
            switch self {
            case .paint:   return "Paint"
            case .fill:    return "Fill"
            case .pick:    return "Pick"
            case .line:    return "Line"
            case .rect:    return "Rectangle"
            case .ellipse: return "Ellipse"
            case .select:  return "Select"
            case .lasso:   return "Lasso"
            }
        }
        /// B, G, I are the bindings pixel editors have used for decades; the
        /// rest are the first letter of the tool, and M is the marquee.
        var key: KeyEquivalent {
            switch self {
            case .paint: return "b"
            case .fill: return "g"
            case .pick: return "i"
            case .line: return "l"
            case .rect: return "r"
            case .ellipse: return "e"
            case .select: return "m"
            case .lasso: return "q"
            }
        }
        var symbol: String {
            switch self {
            case .paint:   return "paintbrush.pointed"
            case .fill:    return "drop"
            case .pick:    return "eyedropper"
            case .line:    return "line.diagonal"
            case .rect:    return "rectangle"
            case .ellipse: return "circle"
            case .select:  return "dot.viewfinder"
            case .lasso:   return "lasso"
            }
        }
        var isShape: Bool { self == .line || self == .rect || self == .ellipse }
    }

    /// Live mirroring: every cell a stroke touches is drawn at its reflection
    /// too, as you draw. Applies to the brush and the shape tools. Not to fill,
    /// where a mirrored flood is as likely to be wrong as right, and not to
    /// selection moves.
    enum Symmetry: String, CaseIterable, Identifiable {
        case off, vertical, horizontal, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .vertical: return "Left / right"
            case .horizontal: return "Top / bottom"
            case .both: return "Both"
            }
        }
    }

    enum DragPhase { case began, changed, ended }

    // MARK: - Undo

    /// A pixel edit touches one frame; adding, deleting or reordering frames
    /// touches the lot. Storing one grid for the common case keeps 50 levels of
    /// undo affordable at 128x128, and the whole array only for the rare one.
    private enum Snapshot {
        case cel(frame: Int, layer: Int, grid: [[Int]])
        case structure(layers: [LayerInfo], frames: [Frame], current: Int, layer: Int,
                       palette: Palette)
    }
    private var undoStack: [Snapshot] = []
    /// Where the current stroke began, held back until it changes something.
    private var pendingStroke: Snapshot?
    private var redoStack: [Snapshot] = []
    private let undoLimit = 50
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Status

    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var lastExport: URL?
    @Published var log: [LogLine] = []

    struct LogLine: Identifiable {
        let id = UUID()
        let kind: String
        let message: String
    }

    /// An export look: a palette and a screen filter, applied on the way out.
    /// The grid is never touched, which is why the clean export stays clean and
    /// these sit beside it rather than replacing it.
    struct Look: Identifiable, Hashable {
        let id: String
        let name: String
        let filtered: Bool
    }

    @Published var looks: [Look] = []

    // MARK: - Gradient fill

    @Published var showingGradient = false
    @Published var gradFrom: Color = .black
    @Published var gradTo: Color = .white
    @Published var gradMode: GradientMode = .vertical
    @Published var gradBands: Int = 5
    @Published var gradDither = false

    enum GradientMode: String, CaseIterable, Identifiable {
        case vertical, horizontal, diagonal, radial
        var id: String { rawValue }
        var label: String {
            switch self {
            case .vertical: return "Down"
            case .horizontal: return "Across"
            case .diagonal: return "Diagonal"
            case .radial: return "Radial"
            }
        }
    }

    /// Seed the wells from the palette so the sheet opens on something sensible
    /// rather than black-to-white every time.
    func openGradient() {
        guard !isEmpty else { return }
        let cols = palette.colors
        let fromIdx = (selectedIndex >= 0 && selectedIndex < cols.count) ? selectedIndex : 0
        gradFrom = Palettes.color(cols[fromIdx])
        // The furthest colour by brightness, not simply the last one: on a
        // two-colour palette "selected" and "last" are often the same swatch,
        // and the sheet opened on black-to-black.
        func luma(_ hex: String) -> Double {
            let c = NSColor(Palettes.color(hex)).usingColorSpace(.sRGB) ?? .black
            return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        }
        let here = luma(cols[fromIdx])
        let far = cols.enumerated().max { abs(luma($0.element) - here) < abs(luma($1.element) - here) }
        gradTo = Palettes.color(far?.element ?? "#ffffff")
        showingGradient = true
    }

    /// Fills the selection if there is one, the whole cel otherwise. The bands
    /// it needs are appended to the palette, so nothing already on the canvas
    /// changes meaning.
    func applyGradient(from: String, to: String) {
        guard !isEmpty else { return }
        let r = selection?.clamped(to: size)
        let mask = selectionMask
        let rect = r.map { [$0.x0, $0.y0, $0.x1, $0.y1] } ?? [0, 0, size - 1, size - 1]
        let before = palette.colors.count
        Task {
            do {
                let reply = try await NibClient.shared.send([
                    "cmd": "gradient", "grid": grid, "palette": palette.colors,
                    "rect": rect, "from": from, "to": to,
                    "bands": gradBands, "mode": gradMode.rawValue, "dither": gradDither,
                ])
                guard var g = reply["grid"] as? [[Int]],
                      let cols = reply["palette"] as? [String] else { return }
                if let mask, let r {
                    let old = grid
                    for y in r.y0...r.y1 {
                        for x in r.x0...r.x1 where !mask.contains(Cell(x: x, y: y)) { g[y][x] = old[y][x] }
                    }
                }
                beginStructuralChange()
                setPalette(cols, named: customName)
                frames[currentFrame].cels[currentLayer] = g
                markEdited()
                showingGradient = false
                let added = cols.count - before
                note("gradient", "\(gradBands) bands \(gradMode.label.lowercased())\(gradDither ? ", dithered" : "")"
                     + (r != nil ? " in the selection" : "")
                     + " — \(added) new colour\(added == 1 ? "" : "s")")
            } catch {
                errorMessage = error.localizedDescription
                note("error", error.localizedDescription)
            }
        }
    }

    // MARK: - Effects

    /// An effect computed at *cell* resolution: it rewrites the active cel and
    /// appends whatever new colours it needed to the palette. Unlike a look this
    /// lands in the grid, so you can keep drawing on the result.
    struct Effect: Identifiable, Hashable {
        let id: String
        let name: String
        let note: String
    }

    @Published var effects: [Effect] = []

    func loadEffects() async {
        guard let reply = try? await NibClient.shared.send(["cmd": "effects"]),
              let raw = reply["effects"] as? [[String: Any]] else { return }
        effects = raw.compactMap {
            guard let id = $0["id"] as? String, let name = $0["name"] as? String else { return nil }
            return Effect(id: id, name: name, note: $0["note"] as? String ?? "")
        }
    }

    /// Applies to the active cel only, like every other tool, so you can put a
    /// CRT on the sprite and leave the background alone.
    func applyEffect(_ id: String) {
        guard !isEmpty else { return }
        let before = palette.colors.count
        Task {
            do {
                let reply = try await NibClient.shared.send([
                    "cmd": "effect", "grid": grid, "palette": palette.colors, "effect": id,
                ])
                guard let g = reply["grid"] as? [[Int]],
                      let cols = reply["palette"] as? [String] else { return }
                beginStructuralChange()
                // The daemon only ever appends, so every index already on the
                // canvas still means what it meant.
                setPalette(cols, named: customName)
                frames[currentFrame].cels[currentLayer] = g
                markEdited()
                let name = effects.first { $0.id == id }?.name ?? id
                note("effect", "\(name) — \(cols.count - before) new colour\(cols.count - before == 1 ? "" : "s"), \(cols.count) total")
                if reply["full"] as? Bool == true {
                    note("error", "Palette hit 255 colours; some of the effect was dropped.")
                }
            } catch {
                errorMessage = error.localizedDescription
                note("error", error.localizedDescription)
            }
        }
    }

    // MARK: - Looks

    @Published var previewLook: String = "screen"
    @Published var previewImage: NSImage?
    @Published var isPreviewing = false
    /// Only render while the panel is actually up: it is a socket round trip and
    /// a full-resolution filter, and nobody needs that for a hidden window.
    @Published var previewOpen = false { didSet { if previewOpen { schedulePreview() } } }
    private var previewTask: Task<Void, Never>?

    /// Re-light the palette between a look's two colours, **index for index**.
    ///
    /// Deliberately not routed through `remap`: the duotone inverts, so nearest-
    /// colour matching would send the paper to the brightest phosphor and turn
    /// the sprite inside out. Here index 0 stays index 0 and only its colour
    /// changes, so not a single pixel moves and you carry on drawing in green.
    func recolour(to lookID: String) {
        guard !isEmpty else { return }
        Task {
            do {
                let reply = try await NibClient.shared.send([
                    "cmd": "duotone", "palette": palette.colors, "look": lookID,
                ])
                guard let colors = reply["colors"] as? [String] else { return }
                let name = looks.first { $0.id == lookID }?.name ?? lookID
                beginStructuralChange()
                suspendControls = true
                let p = Palette(id: "look-\(lookID)", name: name, colors: colors)
                palette = p
                extracted = p
                suspendControls = false
                // The colour now lives in the palette, so the preview must stop
                // adding it: re-lighting an already-lit palette inverts it back
                // and the sprite turns inside out. What is left to preview is
                // the screen itself.
                previewLook = "screen"
                markEdited()
                note("palette", "Recoloured to \(name), index for index — no pixels changed")
                await renderPreview()
            } catch {
                errorMessage = error.localizedDescription
                note("error", error.localizedDescription)
            }
        }
    }

    /// Debounced, because it fires on every stroke.
    func schedulePreview() {
        guard previewOpen else { return }
        previewTask?.cancel()
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled, self.previewOpen else { return }
            await self.renderPreview()
        }
    }

    func renderPreview() async {
        guard !isEmpty else { previewImage = nil; return }
        isPreviewing = true
        defer { isPreviewing = false }
        // Big enough for the grille to exist, small enough to stay a panel.
        let scale = max(4, min(16, 768 / max(1, size)))
        do {
            let reply = try await NibClient.shared.send([
                "cmd": "render_look", "grid": visible, "palette": palette.colors,
                "scale": scale, "look": previewLook,
            ])
            guard let b64 = reply["png"] as? String,
                  let data = Data(base64Encoded: b64) else { return }
            previewImage = NSImage(data: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadLooks() async {
        guard let reply = try? await NibClient.shared.send(["cmd": "looks"]),
              reply["ready"] as? Bool == true,
              let raw = reply["looks"] as? [[String: Any]] else { return }
        looks = raw.compactMap {
            guard let id = $0["id"] as? String, let name = $0["name"] as? String else { return nil }
            return Look(id: id, name: name, filtered: $0["filtered"] as? Bool ?? false)
        }
    }

    // MARK: - Import spread

    @Published var variants: [Variant] = []
    /// The source as the options saw it (cropped, square), shown first in the
    /// picker. Sent by the daemon so the crop is computed in one place.
    @Published var sourcePreview: NSImage?
    @Published var isGeneratingVariants = false
    @Published var showingVariants = false
    @Published var chosenVariant: UUID?
    /// True once the canvas has been hand-edited since it was set from a
    /// variant. Anything that would replace the whole project checks this first.
    @Published var hasEdits = false
    /// A variant waiting on confirmation because accepting it would discard work.
    @Published var pendingVariant: Variant?
    private var variantCache: [String: [Variant]] = [:]
    private var variantCacheKey: String { "\(gridSize)|\(crop.map { "\($0)" } ?? "default")" }
    /// Bumped by every generation, so events from one superseded mid-stream
    /// (the crop moved, the grid size changed) are dropped, not mixed in.
    private var generation = 0

    @Published var extracted: Palette?
    @Published var extractCount: Int = 16
    /// Set while code is assigning several controls at once, so that loading a
    /// project or applying a variant cannot kick off a quantise nobody asked for.
    private var suspendControls = false

    // 8 and 16 are gone: nothing survives the reduction at those sizes. 128 is
    // kept for busy sources, but it barely reads as pixel art.
    static let sizes = [32, 48, 64, 128]

    /// One option in the import spread. Every parameter measured during this
    /// project was right for some drawings and wrong for others, so the app
    /// offers a spread and lets the user point rather than guessing once.
    struct Variant: Identifiable {
        let id = UUID()
        let index: Int
        let label: String
        let grid: [[Int]]
        let palette: Palette
    }

    var sourceAvailable: Bool {
        guard let u = sourceURL else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    // MARK: - Document

    func retitle() {
        window?.isDocumentEdited = isDirty
        window?.title = projectURL?.deletingPathExtension().lastPathComponent ?? "Nib"
    }

    /// Ask before throwing work away. Lives on the store rather than the app
    /// delegate because every route into it -- the menu, the header button, a
    /// dropped file -- has to go through the same question, and only one of
    /// those routes runs through the delegate.
    @discardableResult
    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save this project first?"
        alert.informativeText = "It has changes that are not on disk."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            return !isDirty          // a cancelled save panel is a cancelled action
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func newDocument() {
        guard confirmDiscard() else { return }
        let last = UserDefaults.standard.integer(forKey: "Nib.newSize")
        guard let size = NewPanel.run(sizes: Self.sizes,
                                      initial: Self.sizes.contains(last) ? last : 48)
        else { return }
        UserDefaults.standard.set(size, forKey: "Nib.newSize")
        newProject(size: size)
    }

    func newProject(size: Int = 48) {
        stopPlaying()
        suspendControls = true
        gridSize = size
        palette = Palettes.mono
        suspendControls = false
        sourceURL = nil
        sourceSize = nil
        projectURL = nil
        extracted = nil
        variants.removeAll()
        variantCache.removeAll()
        sourcePreview = nil
        chosenVariant = nil
        showingVariants = false
        selection = nil
        undoStack.removeAll(); redoStack.removeAll()
        layers = [LayerInfo(name: "Layer 1")]
        frames = [Frame.blank(size: size, layers: 1)]
        currentFrame = 0
        currentLayer = 0
        fps = 8
        selectedIndex = 1
        hasEdits = false
        isDirty = false
        lastJob = nil
        log.removeAll()
        note("new", "Blank \(size)x\(size)")
    }

    func snapshotProject() -> Project {
        var src: Project.Source?
        if let u = sourceURL, let id = chosenVariant,
           let v = variants.first(where: { $0.id == id }) {
            src = Project.Source(path: u.path, gridSize: gridSize, trim: nil, crop: crop,
                                 inkBias: nil, method: nil,
                                 pickedLabel: v.label, pickedGrid: v.grid,
                                 pickedPalette: v.palette.colors)
        }
        return Project(layers: layers, palette: palette.colors, paletteName: palette.name,
                       selectedIndex: selectedIndex, frames: frames,
                       fps: fps, source: src)
    }

    func save() {
        guard let url = projectURL else { saveAs(); return }
        write(to: url)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ProjectFile.type]
        panel.nameFieldStringValue =
            (projectURL?.deletingPathExtension().lastPathComponent
             ?? sourceURL?.deletingPathExtension().lastPathComponent
             ?? "Untitled") + ".\(ProjectFile.ext)"
        panel.prompt = "Save"
        panel.message = "Save this project as a Nib project (.\(ProjectFile.ext))"
        // Show the extension. macOS hides it by default, so the panel read
        // "Save As: Chester" and gave no clue what kind of file that was.
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        do {
            try ProjectFile.write(snapshotProject(), to: url)
            projectURL = url
            isDirty = false
            note("save", url.lastPathComponent)
            UserDefaults.standard.set(url.path, forKey: "Nib.lastProject")
        } catch {
            errorMessage = error.localizedDescription
            note("error", "Could not save: \(error.localizedDescription)")
        }
    }

    /// Load a `.nibart`. Deliberately not routed through `open(_:)`: that always
    /// rebuilds the import spread, which is exactly what a saved project should
    /// not do -- the point of saving is to come back to the pixels you left.
    func load(_ url: URL) {
        do {
            let p = try ProjectFile.read(url)
            stopPlaying()
            suspendControls = true
            // Older files carry names that grew a ", edited" per change, e.g.
            // "Fine, 4 tone, edited, edited". Normalise on the way in.
            var name = p.paletteName
            while name.hasSuffix(", edited") { name.removeLast(", edited".count) }
            if name != p.paletteName { name += " (edited)" }
            let pal = Palette(id: "project", name: name, colors: p.palette)
            palette = pal
            extracted = pal
            if let s = p.source {
                sourceURL = URL(fileURLWithPath: s.path)
                sourceSize = NSImage(contentsOfFile: s.path)?.size
                gridSize = s.gridSize
                crop = s.crop
            } else {
                sourceURL = nil; sourceSize = nil
            }
            suspendControls = false

            variants.removeAll()
            variantCache.removeAll()
            sourcePreview = nil
            chosenVariant = nil
            if let s = p.source {
                // Rebuilt so Revert works without the source file. Options
                // regenerates the rest of the spread if the image is still there.
                let v = Variant(index: 0, label: s.pickedLabel, grid: s.pickedGrid,
                                palette: Palette(id: "picked", name: s.pickedLabel,
                                                 colors: s.pickedPalette))
                variants = [v]
                chosenVariant = v.id
            }
            showingVariants = false
            selection = nil
            undoStack.removeAll(); redoStack.removeAll()
            layers = p.layers.isEmpty ? [LayerInfo(name: "Layer 1")] : p.layers
            frames = p.frames.isEmpty ? [Frame.blank(size: gridSize, layers: layers.count)] : p.frames
            currentFrame = 0
            // The top of the stack, not index 0. `layers` is stored bottom-first,
            // so 0 is the *background*: opening a layered project put you on it
            // and the first stroke went underneath everything.
            currentLayer = topLayer
            fps = p.fps
            selectedIndex = min(max(0, p.selectedIndex), max(0, p.palette.count - 1))
            projectURL = url
            hasEdits = false
            isDirty = false
            log.removeAll()
            note("open", "\(url.lastPathComponent) — \(frames.count) frame\(frames.count == 1 ? "" : "s")")
            if p.source != nil && !sourceAvailable {
                note("note", "Source image has moved; Options is unavailable, Revert still works.")
            }
            UserDefaults.standard.set(url.path, forKey: "Nib.lastProject")
        } catch {
            errorMessage = error.localizedDescription
            note("error", "Could not open: \(error.localizedDescription)")
        }
    }

    // MARK: - Live link

    /// Replace the canvas with a document that arrived from outside the app, as
    /// one undo step.
    ///
    /// Whole documents rather than operations: the sender already has an
    /// implementation of every edit it can make, and asking the app to carry a
    /// second one would mean two copies of flip and gradient drifting apart.
    /// This keeps the app's job to "receive a document, make it undoable".
    ///
    /// `version` is what the sender started from. Refusing a stale one is the
    /// same rule the file path uses when it will not save over a file that
    /// changed underneath it, and it matters more here: the canvas can change
    /// while the sender is thinking.
    func applyExternal(_ p: Project, label: String, basedOn version: Int?) throws {
        if let v = version, v != documentVersion {
            throw NibError.stale(expected: v, actual: documentVersion)
        }
        guard !p.frames.isEmpty, !p.layers.isEmpty else {
            throw NibError.badDocument("a document with no frames or no layers")
        }
        let width = p.frames[0].cels.first?.first?.count ?? 0
        guard p.frames.allSatisfy({ $0.cels.count == p.layers.count }) else {
            throw NibError.badDocument("every frame needs one cel per layer")
        }
        stopPlaying()
        beginStructuralChange()
        // Held across the lot: `palette` and `gridSize` are import controls, and
        // assigning them while the spread is open would rebuild it.
        suspendControls = true
        let pal = Palette(id: "project", name: p.paletteName, colors: p.palette)
        palette = pal
        if !Palettes.all.contains(pal) { extracted = pal }
        if width > 0 { gridSize = width }
        suspendControls = false
        layers = p.layers
        frames = p.frames
        currentFrame = min(currentFrame, p.frames.count - 1)
        currentLayer = min(currentLayer, p.layers.count - 1)
        fps = p.fps
        selectedIndex = min(max(0, p.selectedIndex), max(0, p.palette.count - 1))
        selection = nil
        markEdited()
        note("claude", label)
    }

    /// Reopen whatever was last saved. Losing your place between runs is the
    /// thing saving was meant to fix, so it fixes it all the way.
    func restoreLastProject() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: "Nib.lastProject"),
              FileManager.default.fileExists(atPath: path) else { return false }
        load(URL(fileURLWithPath: path))
        return projectURL != nil
    }

    /// One panel for both kinds of file, routed by extension. Two menu items
    /// that both say "open" is the sort of thing that makes you pick the wrong one.
    /// Where Open starts. Nil lets macOS use wherever you were last, which is
    /// the right default; set it when your drawings live in one folder.
    static var openFolder: URL? {
        get { UserDefaults.standard.string(forKey: "Nib.openFolder").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "Nib.openFolder") }
    }

    func chooseFile() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ProjectFile.type, .image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Nib project or an image"
        if let folder = Self.openFolder { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url { openAny(url) }
    }

    /// Pick the folder Open starts in, or clear it.
    func chooseOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.message = "Open starts here. Cancel to go back to wherever you were last."
        if let folder = Self.openFolder { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url {
            Self.openFolder = url
            note("open", "starts in \(url.lastPathComponent)")
        }
    }

    func openAny(_ url: URL) {
        if url.pathExtension.lowercased() == ProjectFile.ext { load(url) } else { open(url) }
    }

    // MARK: - Import

    /// Importing an image replaces the project. Confirmed as the wanted
    /// behaviour: one project is one source drawing, and the frames are what you
    /// build from it by hand.
    func open(_ url: URL) {
        stopPlaying()
        sourceURL = url
        sourceSize = NSImage(contentsOf: url)?.size
        projectURL = nil
        lastExport = nil
        lastJob = nil
        extracted = nil
        variantCache.removeAll()
        sourcePreview = nil
        crop = nil
        selection = nil
        undoStack.removeAll(); redoStack.removeAll()
        log.removeAll()
        note("open", url.lastPathComponent)
        generateVariants()
    }

    /// The Options button. After loading a project the spread holds only the
    /// option that was picked, so rebuild it from the source when there is one.
    func showOptions() {
        showingVariants = true
        if variants.count <= 1 && sourceAvailable { generateVariants() }
    }

    /// The crop tool's frame, on release. Rebuilds the options from it.
    func setCrop(_ box: [Int]) {
        guard box != crop else { return }
        crop = box
        generateVariants()
    }

    /// Back to the daemon's default frame.
    func resetCrop() {
        crop = nil
        generateVariants(force: true)
    }

    func generateVariants(force: Bool = false) {
        guard let url = sourceURL, sourceAvailable else { return }
        showingVariants = true

        if !force, let cached = variantCache[variantCacheKey], !cached.isEmpty {
            variants = cached
            note("options", "from cache")
            return
        }

        variants.removeAll()
        chosenVariant = nil
        isGeneratingVariants = true
        errorMessage = nil
        generation += 1
        let mine = generation
        var request: [String: Any] = ["cmd": "variants", "path": url.path, "size": gridSize]
        if let crop { request["crop"] = crop }

        Task {
            defer { if generation == mine { isGeneratingVariants = false } }
            do {
                _ = try await NibClient.shared.stream(request) { event in
                    guard let e = event["event"] as? [String: Any] else { return }
                    let kind = e["kind"] as? String ?? ""
                    Task { @MainActor in
                        guard self.generation == mine else { return }
                        if kind == "analysed" {
                            let of = e["of"] as? String ?? "?"
                            if let box = e["crop"] as? [Int] { self.crop = box }
                            if let px = e["image_size"] as? [Int], px.count == 2 {
                                self.sourcePixels = CGSize(width: px[0], height: px[1])
                            }
                            // The whole source image: it belongs to the file, not
                            // to this grid size or crop, so it is replaced only
                            // when the source is. Keying it per option set made
                            // the Original column vanish on a cache hit, and the
                            // spread visibly jumped wider and back.
                            if let b64 = e["preview"] as? String, let data = Data(base64Encoded: b64) {
                                self.sourcePreview = NSImage(data: data)
                            }
                            self.note("kind", "\(of == "line_art" ? "line art" : "colour") — building options")
                        } else if kind == "variant",
                                  let g = e["grid"] as? [[Int]],
                                  let cols = e["palette"] as? [String] {
                            let v = Variant(
                                index: e["index"] as? Int ?? self.variants.count,
                                label: e["label"] as? String ?? "option",
                                grid: g,
                                palette: Palette(id: "v\(self.variants.count)",
                                                 name: e["label"] as? String ?? "option",
                                                 colors: cols)
                            )
                            self.variants.append(v)
                        }
                    }
                }
                guard generation == mine else { return }
                variantCache[variantCacheKey] = variants
                note("pass", "\(variants.count) options ready")
            } catch {
                errorMessage = error.localizedDescription
                note("error", error.localizedDescription)
            }
        }
    }

    func choose(_ v: Variant) {
        // Taking an option replaces every frame, and there is no undo across it.
        if (hasEdits || frames.count > 1), chosenVariant != v.id {
            pendingVariant = v
            return
        }
        apply(v)
    }

    func confirmPending() {
        guard let v = pendingVariant else { return }
        pendingVariant = nil
        apply(v)
    }

    func cancelPending() { pendingVariant = nil }

    /// Back to the option as it was picked, for this frame. Re-running the
    /// quantiser here used the averaging path even when the variant came from
    /// the threshold path, so "revert" quietly returned a different sprite.
    func revertToPicked() {
        guard let id = chosenVariant, let v = variants.first(where: { $0.id == id }) else {
            note("error", "Nothing to revert to — pick an option first.")
            return
        }
        beginStroke()
        grid = v.grid
        hasEdits = false
        markEdited()
        note("revert", v.label + (layers.count > 1 ? " into \(layers[currentLayer].name)" : ""))
    }

    private func apply(_ v: Variant) {
        suspendControls = true
        palette = v.palette
        extracted = v.palette
        suspendControls = false
        undoStack.removeAll(); redoStack.removeAll()
        selection = nil
        layers = [LayerInfo(name: "Layer 1")]
        frames = [Frame(cels: [v.grid])]
        currentFrame = 0
        currentLayer = 0
        chosenVariant = v.id
        showingVariants = false
        hasEdits = false
        isDirty = true
        note("pick", v.label)
    }

    /// Median cut over the source. On a colour image this matters more than any
    /// other control: a fixed palette turned a green and purple gradient yellow
    /// and cyan, and a palette taken from the image cannot make that mistake.
    func extractPalette() {
        guard let url = sourceURL, sourceAvailable else { return }
        errorMessage = nil
        Task {
            do {
                let reply = try await NibClient.shared.send([
                    "cmd": "extract_palette", "path": url.path, "colors": extractCount,
                ])
                guard let colors = reply["colors"] as? [String], !colors.isEmpty else { return }
                let p = Palettes.extracted(colors)
                extracted = p
                note("palette", "Extracted \(colors.count) colours from the image")
                palette = p
            } catch {
                errorMessage = error.localizedDescription
                note("error", error.localizedDescription)
            }
        }
    }

    // MARK: - Palette

    /// The colour the swatch picker is holding, ready to add or to replace with.
    @Published var draftColour: Color = .red

    /// GIF keeps one index for transparency, so 255 is the ceiling that matters.
    static let maxColours = 255

    /// Swap the palette without remapping.
    ///
    /// Editing a swatch must leave index 2 as index 2 and only change what
    /// colour that is. Going through `remap` would look for the *nearest* colour
    /// to the old one and could land on a different index entirely, moving
    /// pixels that the user only meant to recolour.
    private func setPalette(_ colors: [String], named: String) {
        suspendControls = true
        let p = Palette(id: "custom", name: named, colors: colors)
        palette = p
        extracted = p
        suspendControls = false
        if selectedIndex >= colors.count { selectedIndex = max(0, colors.count - 1) }
    }

    /// Appended once, never twice. This used to add ", edited" on every change
    /// and produced "Fine, 4 tone, edited, edited" in the picker.
    private var customName: String {
        palette.name.hasSuffix(" (edited)") ? palette.name : palette.name + " (edited)"
    }

    /// Append. Nothing uses the new index yet, so no pixel can change.
    func addColour(_ hex: String) {
        guard !palette.colors.contains(hex) else {
            selectedIndex = palette.colors.firstIndex(of: hex) ?? selectedIndex
            note("palette", "\(hex) is already in the palette")
            return
        }
        guard palette.colors.count < Self.maxColours else {
            note("error", "A palette holds at most \(Self.maxColours) colours.")
            return
        }
        beginStructuralChange()
        setPalette(palette.colors + [hex], named: customName)
        selectedIndex = palette.colors.count - 1
        markEdited()
        note("palette", "Added \(hex) — \(palette.colors.count) colours")
    }

    /// A darker or lighter step of a swatch, appended as a new swatch and
    /// selected, so the next stroke paints with it. Nothing already on the
    /// canvas changes. Repeating it walks a ramp.
    func addShade(of idx: Int, darker: Bool) {
        guard palette.colors.indices.contains(idx) else { return }
        addColour(Palettes.shade(palette.colors[idx], darker: darker))
    }

    /// Put a swatch in the colour well, as the starting point for a new colour.
    /// The colour panel opens on it, so brightness, hue and the rest are one
    /// drag away; `+` then adds the result.
    func startFrom(_ idx: Int) {
        guard palette.colors.indices.contains(idx) else { return }
        draftColour = Palettes.color(palette.colors[idx])
    }

    /// Change what a swatch *is*. Every cell already carrying that index changes
    /// colour; none of them move.
    func replaceColour(at idx: Int, with hex: String) {
        guard palette.colors.indices.contains(idx), palette.colors[idx] != hex else { return }
        beginStructuralChange()
        var colors = palette.colors
        let was = colors[idx]
        colors[idx] = hex
        setPalette(colors, named: customName)
        markEdited()
        note("palette", "Swatch \(idx): \(was) → \(hex), \(usage[idx] ?? 0) cells")
    }

    /// Send every cell of one colour to another, everywhere.
    ///
    /// Not the same as Replace, and both are wanted. Replace changes what a
    /// swatch *is*, so its cells stay its cells and only look different. This
    /// moves the cells to a colour you already have, and leaves the old swatch
    /// behind, empty, in case you want to paint with it again.
    ///
    /// Project-wide rather than this cel: a palette entry means the same thing
    /// in every frame and layer, so changing what uses it halfway would leave
    /// the document saying two things at once.
    func swapColour(from: Int, to: Int) {
        guard from != to,
              palette.colors.indices.contains(from),
              palette.colors.indices.contains(to) else { return }
        let moved = usage[from] ?? 0
        guard moved > 0 else {
            note("palette", "Nothing is using \(palette.colors[from])")
            return
        }
        beginStructuralChange()
        frames = frames.map { frame in
            var f = frame
            f.cels = frame.cels.map { cel in cel.map { $0.map { $0 == from ? to : $0 } } }
            return f
        }
        selectedIndex = to
        markEdited()
        note("palette", "\(moved) cell\(moved == 1 ? "" : "s") of \(palette.colors[from]) → \(palette.colors[to])")
    }

    /// Drop a swatch, merging whatever used it into the nearest survivor.
    ///
    /// This one *does* remap, and has to: every index above the removed one
    /// shifts down, so the grids have to be rewritten. Nearest-in-Lab is also
    /// the behaviour you want -- removing a near-duplicate merges it into its
    /// neighbour, which is what palette tidying is for.
    func removeColour(at idx: Int) {
        guard palette.colors.count > 2, palette.colors.indices.contains(idx) else {
            if palette.colors.count <= 2 { note("error", "A palette needs at least two colours.") }
            return
        }
        let old = palette.colors
        var colors = old
        let gone = colors.remove(at: idx)
        // Read the census now: by the time the log line is written the grids
        // have been rewritten and recounted, so asking then always says zero.
        let moving = usage[idx] ?? 0
        Task {
            do {
                let reply = try await NibClient.shared.send([
                    "cmd": "remap", "from": old, "to": colors,
                ])
                guard let map = reply["map"] as? [Int] else { return }
                beginStructuralChange()
                frames = frames.map { frame in
                    var f = frame
                    f.cels = frame.cels.map { cel in
                        cel.map { $0.map { v in v >= 0 && v < map.count ? map[v] : v } }
                    }
                    return f
                }
                setPalette(colors, named: customName)
                markEdited()
                note("palette", "Removed \(gone); its \(moving) cell\(moving == 1 ? "" : "s") went to \(colors[min(map[idx], colors.count - 1)])")
            } catch {
                errorMessage = error.localizedDescription
                note("error", error.localizedDescription)
            }
        }
    }

    private func paletteChanged(from old: Palette) {
        if selectedIndex >= palette.colors.count { selectedIndex = max(0, palette.colors.count - 1) }
        guard !suspendControls else { return }
        if showingVariants {
            generateVariants()
        } else if old.colors != palette.colors {
            remap(from: old, to: palette)
        }
    }

    /// Switching palette used to re-run the quantiser from the source, which
    /// discarded every hand edit and, now, would discard the whole animation.
    /// Remap instead: nearest colour in Lab, computed once by the daemon that
    /// already owns that code, then applied to every frame as one undo step.
    private func remap(from old: Palette, to new: Palette) {
        guard !frames.isEmpty, !old.colors.isEmpty, !new.colors.isEmpty else { return }
        Task {
            do {
                let reply = try await NibClient.shared.send([
                    "cmd": "remap", "from": old.colors, "to": new.colors,
                ])
                guard let map = reply["map"] as? [Int] else { return }
                // The snapshot has to carry the palette we came *from*. This runs
                // from the palette's own didSet, so by now `palette` is already
                // the new one, and `beginStructuralChange()` would save that --
                // leaving undo to restore the old indices under the new colours,
                // which is a state the document was never in.
                push(.structure(layers: layers, frames: frames,
                                current: currentFrame, layer: currentLayer, palette: old))
                // Rebuilt whole and assigned once. Writing through `frames`
                // cell by cell publishes a change per pixel, and each one
                // re-counts the palette: 7,000 of those for three 48x48 frames,
                // and enough to lock the window up at 128x128.
                frames = frames.map { frame in
                    var f = frame
                    f.cels = frame.cels.map { cel in
                        cel.map { $0.map { v in v >= 0 && v < map.count ? map[v] : v } }
                    }
                    return f
                }
                markEdited()
                let cels = frames.count * max(1, layers.count)
                note("palette", "Remapped \(old.colors.count) → \(new.colors.count) colours across \(cels) cel\(cels == 1 ? "" : "s")")
            } catch {
                errorMessage = error.localizedDescription
                note("error", error.localizedDescription)
            }
        }
    }

    /// Every import control funnels through here, so that code setting several
    /// of them at once cannot trigger a pass per control.
    private func controlChanged() {
        guard !suspendControls, showingVariants else { return }
        generateVariants()
    }

    // MARK: - Frames

    func selectFrame(_ i: Int) {
        guard frames.indices.contains(i) else { return }
        stopPlaying()
        selection = nil
        currentFrame = i
        schedulePreview()
    }

    func addFrame() {
        beginStructuralChange()
        frames.insert(Frame.blank(size: size == 0 ? gridSize : size, layers: layers.count),
                      at: currentFrame + 1)
        currentFrame += 1
        markEdited()
        note("frame", "Added frame \(currentFrame + 1) of \(frames.count)")
    }

    func duplicateFrame() {
        guard frames.indices.contains(currentFrame) else { return }
        beginStructuralChange()
        var copy = frames[currentFrame]
        copy.id = UUID()
        frames.insert(copy, at: currentFrame + 1)
        currentFrame += 1
        markEdited()
        note("frame", "Duplicated to frame \(currentFrame + 1) of \(frames.count)")
    }

    /// Copy this frame, every layer of it. `Duplicate` already covers "another
    /// one right here"; this is for putting a frame somewhere else, which is
    /// how you close a loop by repeating the opening frame at the end.
    func copyFrame() {
        guard frames.indices.contains(currentFrame) else { return }
        frameClipboard = frames[currentFrame]
        note("copy", "Frame \(currentFrame + 1), \(frames[currentFrame].cels.count) layer\(frames[currentFrame].cels.count == 1 ? "" : "s")")
        objectWillChange.send()      // canPasteFrame is derived, not published
    }

    /// Paste it in after this frame. Inserting rather than replacing: losing a
    /// frame to a misfired paste costs more than an extra frame does, and the
    /// extra one is a Delete away.
    func pasteFrame() {
        guard var f = frameClipboard else { return }
        // The copy may be older than the layer stack it lands in: a layer added
        // or deleted since would leave a frame with the wrong number of cels,
        // which is the one shape `frames` must never take.
        // `size`, the canvas, not `gridSize`, which is the import setting and
        // only matches the canvas for a project that came from an import.
        let n = size
        let blank = Array(repeating: Array(repeating: -1, count: n), count: n)
        guard f.cels.allSatisfy({ $0.count == n && $0.allSatisfy { $0.count == n } }) else {
            note("error", "That frame is \(f.cels.first?.count ?? 0) cells; this canvas is \(n).")
            return
        }
        f.cels = (0..<layers.count).map { $0 < f.cels.count ? f.cels[$0] : blank }
        f.id = UUID()
        beginStructuralChange()
        frames.insert(f, at: currentFrame + 1)
        currentFrame += 1
        markEdited()
        note("paste", "Frame \(currentFrame + 1) of \(frames.count)")
    }

    func deleteFrame() {
        guard frames.count > 1, frames.indices.contains(currentFrame) else { return }
        beginStructuralChange()
        frames.remove(at: currentFrame)
        currentFrame = min(currentFrame, frames.count - 1)
        markEdited()
        note("frame", "Deleted — \(frames.count) left")
    }

    func moveFrame(by delta: Int) {
        let to = currentFrame + delta
        guard frames.indices.contains(currentFrame), frames.indices.contains(to) else { return }
        beginStructuralChange()
        frames.swapAt(currentFrame, to)
        currentFrame = to
        markEdited()
    }

    func setHold(_ hold: Int) {
        guard frames.indices.contains(currentFrame) else { return }
        beginStructuralChange()
        frames[currentFrame].hold = max(1, min(8, hold))
        markEdited()
    }

    // MARK: - Rolling

    /// Shift this frame, wrapping. Never called by picking a direction -- only
    /// by the Roll button or an Option-arrow, both of which say what they do.
    func roll(_ direction: RollDirection) {
        guard !isEmpty else { return }
        rollDirection = direction
        let (dx, dy) = direction.delta
        beginStroke()
        grid = Grids.rolled(grid, dx: dx * rollStep, dy: dy * rollStep)
        markEdited()
        note("roll", "\(direction.label) \(rollStep) cell\(rollStep == 1 ? "" : "s")"
             + (layers.count > 1 ? " on \(layers[currentLayer].name)" : ""))
    }

    /// Flip or rotate the selection, or the whole cel if there is none. Like
    /// roll, it touches the active layer only.
    func transform(_ t: Grids.Transform) {
        guard !isEmpty else { return }
        let whole = CellRect(x0: 0, y0: 0, x1: size - 1, y1: size - 1)
        let r = selection?.clamped(to: size) ?? whole
        let (g, moved, mask) = Grids.transformed(grid, rect: r, mask: selectionMask, t)
        guard g != grid else { return }
        beginStroke()
        grid = g
        if let mask { select(mask, rect: Shapes.bounds(mask)) }
        else if selection != nil { selection = moved.clamped(to: size) }
        markEdited()
        note("transform", t.rawValue + (selection == nil ? "" : " selection")
             + (layers.count > 1 ? " on \(layers[currentLayer].name)" : ""))
    }

    /// Turn this frame into a scrolling run.
    ///
    /// Replaces the animation rather than appending to it: the input is one
    /// picture and the output is that picture in motion, so appending would
    /// leave whatever came before stranded in front of it. It is a single undo.
    func buildScroll() {
        guard !isEmpty else { return }
        let base = grid
        let n = base.count
        let count = max(2, rollFrames)
        let (dx, dy) = rollDirection.delta

        let template = frames[currentFrame]
        beginStructuralChange()
        frames = (0..<count).map { i in
            // Keep going: 0, 1, 2, 3... Back and forth: 0, 1, 2, 1 -- a triangle
            // that returns to its start, so it loops at any frame count.
            let t = rollMode == .loop ? i : (i <= count / 2 ? i : count - i)
            let k = t * rollStep
            // Only the active layer moves. Every other layer is carried through
            // unchanged, which is how you get a board scrolling under a sprite
            // that stands still.
            var f = template
            f.id = UUID()
            f.hold = 1
            f.cels[currentLayer] = Grids.rolled(base, dx: dx * k, dy: dy * k)
            return f
        }
        currentFrame = 0
        showingScrollBuilder = false
        markEdited()

        let travel = count * rollStep
        note("roll", "\(count) frames rolling \(rollDirection.label), \(rollStep) cell\(rollStep == 1 ? "" : "s") each")
        if rollMode == .loop && travel != n {
            note("note", travel < n
                 ? "Stops \(n - travel) cells short of a full turn, so the loop will jump. \(n / rollStep) frames would close it."
                 : "Overshoots a full turn by \(travel - n) cells. \(n / rollStep) frames would close it.")
        }
    }

    // MARK: - Layers

    /// The top of the stack. `layers` is bottom-first for compositing's sake, so
    /// this is the last index, and it is what "the layer you are drawing on"
    /// should default to everywhere it is not an explicit choice.
    var topLayer: Int { max(0, layers.count - 1) }

    func selectLayer(_ i: Int) {
        guard layers.indices.contains(i) else { return }
        stopPlaying()
        selection = nil
        currentLayer = i
    }

    /// A new layer goes *above* the current one and is empty in every frame.
    func addLayer() {
        guard !frames.isEmpty else { return }
        beginStructuralChange()
        let n = size == 0 ? gridSize : size
        let at = currentLayer + 1
        layers.insert(LayerInfo(name: "Layer \(layers.count + 1)"), at: at)
        for i in frames.indices {
            frames[i].cels.insert(Array(repeating: Array(repeating: -1, count: n), count: n), at: at)
        }
        currentLayer = at          // draw on what you just made
        markEdited()
        note("layer", "Added \(layers[at].name) — \(layers.count) layers")
    }

    func deleteLayer() {
        guard layers.count > 1, layers.indices.contains(currentLayer) else { return }
        beginStructuralChange()
        let gone = layers[currentLayer].name
        layers.remove(at: currentLayer)
        for i in frames.indices where frames[i].cels.indices.contains(currentLayer) {
            frames[i].cels.remove(at: currentLayer)
        }
        currentLayer = min(currentLayer, layers.count - 1)
        markEdited()
        note("layer", "Deleted \(gone) — \(layers.count) left")
    }

    /// +1 is towards the top of the stack, which is towards the top of the
    /// timeline: the display is reversed but the command reads the way it looks.
    func moveLayer(by delta: Int) {
        let to = currentLayer + delta
        guard layers.indices.contains(currentLayer), layers.indices.contains(to) else { return }
        beginStructuralChange()
        layers.swapAt(currentLayer, to)
        for i in frames.indices where frames[i].cels.indices.contains(to) {
            frames[i].cels.swapAt(currentLayer, to)
        }
        currentLayer = to
        markEdited()
    }

    func toggleLayerVisible(_ i: Int) {
        guard layers.indices.contains(i) else { return }
        beginStructuralChange()
        layers[i].visible.toggle()
        markEdited()
        note("layer", "\(layers[i].name) \(layers[i].visible ? "shown" : "hidden")")
    }

    func renameLayer(_ i: Int, to name: String) {
        guard layers.indices.contains(i), layers[i].name != name else { return }
        layers[i].name = name
        isDirty = true
    }

    /// The frames drawn faintly under the current one.
    ///
    /// Only the cells that *differ* from the current frame are shown. A
    /// conventional onion skin draws the whole neighbouring frame at low alpha,
    /// which works when the background is transparent; Nib's imports have an
    /// opaque white as palette index 0, so that would wash the entire canvas.
    /// Drawing the difference shows exactly what moved, which is the thing you
    /// wanted to see anyway.
    ///
    /// Nearest first, up to `onionRange` either side, never wrapping: a loop's
    /// last frame shown as "before" the first would be a guess about intent.
    var onionPrev: [[[Int]]] {
        guard onionSkin, !isPlaying else { return [] }
        return (1...onionRange).map { currentFrame - $0 }.filter { $0 >= 0 }.map { composite($0) }
    }
    var onionNext: [[[Int]]] {
        guard onionSkin, !isPlaying else { return [] }
        return (1...onionRange).map { currentFrame + $0 }.filter { $0 < frames.count }.map { composite($0) }
    }

    func togglePlay() {
        if isPlaying { stopPlaying(); return }
        guard frames.count > 1 else { return }
        selection = nil
        isPlaying = true
        playTask = Task { @MainActor [weak self] in
            while let self, self.isPlaying, !Task.isCancelled {
                let hold = self.frames.indices.contains(self.currentFrame)
                    ? max(1, self.frames[self.currentFrame].hold) : 1
                let seconds = Double(hold) / max(1, self.fps)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard self.isPlaying, !Task.isCancelled, self.frames.count > 1 else { break }
                self.currentFrame = (self.currentFrame + 1) % self.frames.count
            }
        }
    }

    func stopPlaying() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    // MARK: - Drag handling
    //
    // The canvas reports raw drag events and nothing else. Every tool's meaning
    // lives here, so the preview a shape shows and the pixels it commits come
    // from one function called twice.

    private var dragOrigin: Cell?
    private var dragLast: Cell?
    private var dragErase = false
    /// The grid as it was when a selection move began, so each drag update is a
    /// fresh stamp from a clean state rather than a smear of the last one.
    private var moveSource: [[Int]]?
    private var moveRect: CellRect?
    private var moveMask: Set<Cell>?
    /// Cells the lasso has passed through, in order: the polygon it closes.
    private var lassoPath: [Cell] = []

    func handleDrag(x: Int, y: Int, phase: DragPhase, erase: Bool) {
        guard !isEmpty else { return }
        let c = Cell(x: x, y: y)
        switch phase {
        case .began:
            stopPlaying()
            dragOrigin = c; dragLast = c; dragErase = erase
            switch tool {
            case .pick:
                pick(x: x, y: y)                       // changes no pixels, costs no undo
            case .paint:
                beginStroke(); stamp([c], erase: erase)
            case .fill:
                beginStroke(); fill(x: x, y: y, index: erase ? -1 : selectedIndex)
            case .line, .rect, .ellipse:
                preview = mirrored(shape(from: c, to: c))
            case .select, .lasso:
                // Either tool moves whatever is selected, whichever tool made it.
                if let s = selection, isSelected(c) {
                    beginStroke()
                    moveSource = grid
                    moveRect = s
                    moveMask = selectionMask
                } else if tool == .lasso {
                    lassoPath = [c]
                    select([c], rect: CellRect(c, c))
                } else {
                    select(nil, rect: CellRect(c, c).clamped(to: size))
                }
            }
        case .changed:
            guard let origin = dragOrigin else { return }
            switch tool {
            case .paint:
                // Join up to the last reported cell: a fast mouse skips several,
                // and without this a quick stroke comes out as dots.
                let joined = Shapes.line(from: dragLast ?? c, to: c)
                stamp(joined, erase: dragErase)
            case .fill, .pick:
                break
            case .line, .rect, .ellipse:
                preview = mirrored(shape(from: origin, to: c))
            case .select, .lasso:
                if let src = moveSource, let r = moveRect {
                    moveSelection(from: src, rect: r, mask: moveMask,
                                  dx: c.x - origin.x, dy: c.y - origin.y)
                } else if tool == .lasso {
                    // Joined up for the same reason paint is: a fast mouse
                    // skips cells, and the outline would come out as dots.
                    let from = lassoPath.last ?? c
                    lassoPath += Shapes.line(from: from, to: c)
                        .sorted { abs($0.x - from.x) + abs($0.y - from.y) < abs($1.x - from.x) + abs($1.y - from.y) }
                        .filter { $0 != from }
                    let trail = Set(lassoPath.filter { $0.x >= 0 && $0.x < size && $0.y >= 0 && $0.y < size })
                    select(trail, rect: Shapes.bounds(trail))
                } else {
                    selection = CellRect(origin, c).clamped(to: size)
                }
            }
            dragLast = c
        case .ended:
            switch tool {
            case .line, .rect, .ellipse:
                if !preview.isEmpty {
                    beginStroke()
                    stamp(preview, erase: dragErase, alreadyMirrored: true)
                    preview = []
                }
            case .select, .lasso:
                if moveRect != nil {
                    // moveSelection has already left the selection where it landed.
                } else if tool == .lasso, lassoPath.count > 2 {
                    let cells = Shapes.lasso(lassoPath, size: size)
                    select(cells, rect: Shapes.bounds(cells))
                } else if let s = selection, s.count == 1 {
                    selection = nil          // a click outside clears rather than selecting one cell
                }
                moveSource = nil; moveRect = nil; moveMask = nil; lassoPath = []
            default:
                break
            }
            dragOrigin = nil; dragLast = nil
        }
    }

    private func shape(from a: Cell, to b: Cell) -> Set<Cell> {
        switch tool {
        case .line:    return Shapes.line(from: a, to: b)
        case .rect:    return Shapes.rect(from: a, to: b, filled: fillShapes)
        case .ellipse: return Shapes.ellipse(from: a, to: b, filled: fillShapes)
        default:       return []
        }
    }

    private func mirrored(_ cells: Set<Cell>) -> Set<Cell> {
        guard symmetry != .off else { return cells }
        var out = cells
        for c in cells { out.formUnion(reflections(of: c)) }
        return out
    }

    private func reflections(of c: Cell) -> [Cell] {
        let n = size
        guard n > 0 else { return [] }
        switch symmetry {
        case .off:        return []
        case .vertical:   return [Cell(x: n - 1 - c.x, y: c.y)]
        case .horizontal: return [Cell(x: c.x, y: n - 1 - c.y)]
        case .both:       return [Cell(x: n - 1 - c.x, y: c.y),
                                  Cell(x: c.x, y: n - 1 - c.y),
                                  Cell(x: n - 1 - c.x, y: n - 1 - c.y)]
        }
    }

    /// Change the current frame's grid once, whatever the edit touched.
    ///
    /// `frames` is @Published and re-counts the palette when it changes, so a
    /// write per cell costs a publish and a full recount per cell. A filled
    /// rectangle at 128x128 is 16,384 of them.
    private func mutateCurrent(_ body: (inout [[Int]]) -> Bool) {
        guard hasCel else { return }
        var g = frames[currentFrame].cels[currentLayer]
        guard body(&g) else { return }
        frames[currentFrame].cels[currentLayer] = g
        markEdited()
    }

    private func stamp(_ cells: Set<Cell>, erase: Bool, alreadyMirrored: Bool = false) {
        let all = alreadyMirrored ? cells : mirrored(cells)
        let index = erase ? -1 : selectedIndex
        mutateCurrent { g in
            var changed = false
            for c in all {
                guard c.y >= 0, c.y < g.count, c.x >= 0, c.x < g[c.y].count else { continue }
                guard g[c.y][c.x] != index else { continue }
                g[c.y][c.x] = index
                changed = true
            }
            return changed
        }
    }

    /// Rebuild the whole grid from the snapshot each time the drag moves: clear
    /// the lifted rectangle, stamp it at the offset. Costs one grid copy per
    /// mouse event and gives a live preview with no second rendering path.
    private func moveSelection(from source: [[Int]], rect: CellRect, mask: Set<Cell>?,
                               dx: Int, dy: Int) {
        var g = source
        let n = g.count
        guard n > 0 else { return }
        let r = rect.clamped(to: n)
        let lifted = mask.map { Array($0) }
            ?? (r.y0...r.y1).flatMap { y in (r.x0...r.x1).map { Cell(x: $0, y: y) } }
        for c in lifted { g[c.y][c.x] = -1 }
        var landed: Set<Cell> = []
        for c in lifted {
            let ty = c.y + dy, tx = c.x + dx
            guard ty >= 0, ty < n, tx >= 0, tx < n else { continue }
            g[ty][tx] = source[c.y][c.x]
            landed.insert(Cell(x: tx, y: ty))
        }
        grid = g
        if mask != nil { select(landed, rect: Shapes.bounds(landed)) }
        else { selection = rect.offset(dx: dx, dy: dy).clamped(to: n) }
        markEdited()
    }

    // MARK: - Selection commands

    func selectAll() {
        guard !isEmpty else { return }
        tool = .select
        select(nil, rect: CellRect(x0: 0, y0: 0, x1: size - 1, y1: size - 1))
    }

    func copySelection() {
        guard let r = selection?.clamped(to: size), !isEmpty else { return }
        let g = grid
        // Unselected cells inside a lasso's box are marked, not copied, so a
        // paste leaves whatever is under them alone.
        clipboard = (r.y0...r.y1).map { y in
            (r.x0...r.x1).map { x in isSelected(Cell(x: x, y: y)) ? g[y][x] : Grids.outside }
        }
        note("copy", "\(r.width)x\(r.height) cells")
        objectWillChange.send()      // canPaste is derived, not published
    }

    func cutSelection() {
        copySelection()
        clearSelection()
    }

    func clearSelection() {
        guard let r = selection?.clamped(to: size), !isEmpty else { return }
        beginStroke()
        mutateCurrent { g in
            for y in r.y0...r.y1 {
                for x in r.x0...r.x1 where isSelected(Cell(x: x, y: y)) { g[y][x] = -1 }
            }
            return true
        }
    }

    /// Pasted at the current selection's corner, or the top left if there is
    /// none. Committed straight away rather than floating: a floating paste you
    /// then have to place is a second interaction to learn, and Undo is right there.
    func paste() {
        guard let buf = clipboard, !isEmpty else { return }
        let ox = selection?.x0 ?? 0, oy = selection?.y0 ?? 0
        let n = size
        var pasted: Set<Cell> = []
        var holes = false
        beginStroke()
        mutateCurrent { g in
            for (dy, row) in buf.enumerated() {
                for (dx, v) in row.enumerated() {
                    if v == Grids.outside { holes = true; continue }
                    let y = oy + dy, x = ox + dx
                    guard y >= 0, y < g.count, x >= 0, x < g[y].count else { continue }
                    g[y][x] = v
                    pasted.insert(Cell(x: x, y: y))
                }
            }
            return true
        }
        // A lasso copy pastes back as a lasso selection, so it can be moved as
        // the shape it is rather than as its box.
        if holes { select(pasted, rect: Shapes.bounds(pasted)) }
        else {
            select(nil, rect: CellRect(x0: ox, y0: oy,
                                       x1: ox + (buf.first?.count ?? 1) - 1,
                                       y1: oy + buf.count - 1).clamped(to: n))
        }
        if !tool.selects { tool = .select }
        markEdited()
        note("paste", "\(buf.first?.count ?? 0)x\(buf.count) at \(ox),\(oy)")
    }

    // MARK: - Editing primitives

    /// Call once at the start of a stroke, not per pixel: a stroke is one undo.
    /// Remembers where a stroke started, but does not commit it to the undo
    /// stack until something actually changes.
    ///
    /// It used to push immediately, on mouse-down. Every click on the canvas
    /// therefore added an undo step and **cleared the redo stack** -- including
    /// clicks that changed nothing, like tapping a cell that is already the
    /// selected colour, or erasing an empty one. So: undo, click anywhere to
    /// look at the result, and redo was gone. It also left empty steps in the
    /// undo stack, which is why undo sometimes appeared to do nothing.
    func beginStroke() {
        guard hasCel else { return }
        pendingStroke = .cel(frame: currentFrame, layer: currentLayer,
                             grid: frames[currentFrame].cels[currentLayer])
    }

    /// Called by `markEdited`, so the snapshot lands only when a real change does.
    private func commitPendingStroke() {
        guard let s = pendingStroke else { return }
        pendingStroke = nil
        push(s)
    }

    /// For anything that adds, removes, reorders or rewrites every frame.
    func beginStructuralChange() {
        pendingStroke = nil          // a structural change supersedes a half-started stroke
        push(.structure(layers: layers, frames: frames,
                        current: currentFrame, layer: currentLayer, palette: palette))
    }

    private func push(_ s: Snapshot) {
        undoStack.append(s)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func markEdited() {
        commitPendingStroke()
        hasEdits = true
        isDirty = true
        documentVersion &+= 1
        schedulePreview()
    }

    /// Pick the colour under the cursor. Selects the eraser for a transparent
    /// cell, which is what you mean by picking one.
    func pick(x: Int, y: Int) {
        let g = grid
        guard y >= 0, y < g.count, x >= 0, x < g[y].count else { return }
        selectedIndex = g[y][x]
        note("pick", g[y][x] < 0 ? "transparent" : "\(g[y][x]): \(palette.colors[g[y][x]])")
    }

    /// Flood fill the contiguous region of matching colour, 4-connected.
    /// Diagonal neighbours are deliberately not included: at this scale
    /// 8-connected fill leaks through the corner gaps in a 1px outline.
    func fill(x: Int, y: Int, index: Int) {
        var g = grid
        guard y >= 0, y < g.count, x >= 0, x < g[y].count else { return }
        let target = g[y][x]
        guard target != index else { return }
        let n = g.count
        var stack = [(x, y)]
        var filled = 0
        while let (cx, cy) = stack.popLast() {
            guard cx >= 0, cx < n, cy >= 0, cy < n, g[cy][cx] == target else { continue }
            g[cy][cx] = index
            filled += 1
            stack += [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)]
        }
        if filled > 0 {
            grid = g
            markEdited()
        }
        note("fill", "\(filled) cells")
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(inverse(of: s))
        restore(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(inverse(of: s))
        restore(s)
    }

    private func inverse(of s: Snapshot) -> Snapshot {
        switch s {
        case .cel(let f, let l, _):
            let g = frames.indices.contains(f) && frames[f].cels.indices.contains(l)
                ? frames[f].cels[l] : []
            return .cel(frame: f, layer: l, grid: g)
        case .structure:
            return .structure(layers: layers, frames: frames,
                              current: currentFrame, layer: currentLayer, palette: palette)
        }
    }

    private func restore(_ s: Snapshot) {
        stopPlaying()
        switch s {
        case .cel(let f, let l, let g):
            guard frames.indices.contains(f), frames[f].cels.indices.contains(l) else { return }
            frames[f].cels[l] = g
            currentFrame = f
            currentLayer = l
        case .structure(let ls, let fs, let c, let l, let p):
            // Straight assignment, never a remap: undoing a recolour has to put
            // the old colours back on the same indices, and remapping would
            // re-sort them by nearest colour instead.
            suspendControls = true
            palette = p
            if !Palettes.all.contains(p) { extracted = p }
            suspendControls = false
            layers = ls
            frames = fs
            currentFrame = min(max(0, c), max(0, fs.count - 1))
            currentLayer = min(max(0, l), max(0, ls.count - 1))
        }
        selection = nil
        isDirty = true
        documentVersion &+= 1
    }

    private func recount() {
        var counts: [Int: Int] = [:]
        for row in visible { for v in row { counts[v, default: 0] += 1 } }
        usage = counts
    }

    func note(_ kind: String, _ message: String) {
        log.append(LogLine(kind: kind, message: message))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: - Export

    /// Where an export should land, and how big. Everything used to go to
    /// ~/.nib/output under a generated name at a size fixed by which menu item
    /// you picked, which is fine for a scratch tool and wrong as soon as you are
    /// actually making things.
    private func askExport(kind: String, ext: String, look: String,
                           scales: [Int], initial: Int) -> (url: URL, scale: Int)? {
        ExportPanel.run(base: exportName,
                        suffix: look == "clean" ? "" : "_\(look)",
                        ext: ext,
                        kind: kind,
                        gridSize: size,
                        directory: projectURL?.deletingLastPathComponent(),
                        scales: scales,
                        initial: initial)
    }

    private var exportName: String {
        projectURL?.deletingPathExtension().lastPathComponent
            ?? sourceURL?.deletingPathExtension().lastPathComponent
            ?? "nib"
    }

    /// Everything needed to write the same file again without asking.
    private struct ExportJob { let gif: Bool; let look: String; let scale: Int; let url: URL }
    private var lastJob: ExportJob?

    func export(scale: Int = 8, look: String = "clean") {
        guard !isEmpty else { return }
        guard let pick = askExport(kind: look == "clean" ? "PNG" : "PNG with the \(look) look",
                                   ext: "png", look: look,
                                   scales: ExportPanel.scales(), initial: scale)
        else { return }
        run(ExportJob(gif: false, look: look, scale: pick.scale, url: pick.url))
    }

    func exportGIF(scale: Int = 8, look: String = "clean") {
        guard frames.count > 1 else {
            note("error", "A GIF needs more than one frame.")
            return
        }
        // Capped at 16: a 32x GIF of twenty frames is hundreds of megabytes.
        guard let pick = askExport(kind: look == "clean" ? "GIF" : "GIF with the \(look) look",
                                   ext: "gif", look: look,
                                   scales: ExportPanel.scales(upTo: 16), initial: scale)
        else { return }
        run(ExportJob(gif: true, look: look, scale: pick.scale, url: pick.url))
    }

    /// Same kind, look, size and path as last time, no panel. Export happens
    /// every few minutes while iterating, and the panel was the whole cost.
    /// Falls back to asking when there is no last time.
    func exportAgain() {
        guard let job = lastJob else { export(); return }
        if job.gif, frames.count < 2 {
            note("error", "A GIF needs more than one frame.")
            return
        }
        run(job)
    }

    private func run(_ job: ExportJob) {
        guard !isEmpty else { return }
        lastJob = job
        isWorking = true
        errorMessage = nil
        var request: [String: Any] = [
            "palette": palette.colors, "scale": job.scale, "name": exportName,
            "look": job.look, "path": job.url.path,
        ]
        if job.gif {
            request["cmd"] = "export_gif"
            request["fps"] = fps
            request["frames"] = frames.map {
                ["grid": $0.composite(layers), "hold": $0.hold] as [String: Any]
            }
        } else {
            request["cmd"] = "export"
            request["grid"] = visible
        }
        let count = frames.count
        Task {
            defer { isWorking = false }
            do {
                let reply = try await NibClient.shared.send(request)
                if let p = reply["path"] as? String {
                    lastExport = URL(fileURLWithPath: p)
                    let name = URL(fileURLWithPath: p).lastPathComponent
                    note("export", job.gif ? "\(name) — \(count) frames at \(Int(fps))fps" : name)
                }
            } catch {
                errorMessage = error.localizedDescription
                note("error", error.localizedDescription)
            }
        }
    }
}
