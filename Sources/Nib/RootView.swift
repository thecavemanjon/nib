import SwiftUI
import UniformTypeIdentifiers

/// The window's content: canvas left, controls right, split by a hairline.
/// Not named CardView; this is a window, not a card.
struct RootView: View {
    @EnvironmentObject private var store: CanvasStore
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            canvasColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
                .overlay(Color.primary.opacity(0.12))
            controlsColumn
                .frame(width: WindowSize.controls)
        }
        .background(VisualEffectBackground())
        .overlay {
            if let v = store.pendingVariant { replaceConfirm(v) }
        }
        .sheet(isPresented: $store.showingScrollBuilder) { scrollBuilder }
        .sheet(isPresented: $store.showingGradient) { gradientSheet }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            loadFirst(from: providers)
        }
    }

    // MARK: - Canvas

    private var canvasColumn: some View {
        VStack(spacing: 8) {
            // Fixed height whether or not an image is open, so opening one
            // cannot shift the canvas downward.
            sourceHeader
                .frame(height: WindowSize.aboveCanvas)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                if store.showingVariants {
                    variantPicker
                } else if store.isEmpty {
                    emptyState
                } else {
                    canvas
                }
                if store.isWorking {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error = store.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !store.isEmpty && !store.showingVariants {
                toolBar
                Timeline()
            }
            processLog
        }
        .padding(16)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(8)
            }
        }
    }

    /// What happened, front to back. Kept because it has caught two bugs that
    /// were invisible in the output: a file that quantised twice, and a pass
    /// that silently did nothing while reporting success.
    private var processLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if store.log.isEmpty {
                        Text("Nothing run yet")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.log) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.kind)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(colour(for: line.kind))
                                .frame(width: 42, alignment: .leading)
                            Text(line.message)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 92)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onChange(of: store.log.count) {
                // Anchored to the bottom: without it the newest line lands at
                // the top of the box and the lines under it are the ones you
                // have already read.
                if let last = store.log.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func colour(for kind: String) -> Color {
        switch kind {
        case "error": return .orange
        case "frame", "paste", "copy": return .accentColor
        case "done", "pass", "save", "export": return .green
        default: return .secondary
        }
    }

    /// The import spread. Options stream in as the daemon produces them, so the
    /// grid fills rather than sitting blank.
    private var variantPicker: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(store.isGeneratingVariants ? "Building options…" : "Pick a starting point")
                    .font(.system(size: 12, weight: .semibold))
                if store.isGeneratingVariants {
                    ProgressView().scaleEffect(0.45).frame(width: 14, height: 14)
                }
                Spacer()
                if !store.variants.isEmpty && store.chosenVariant != nil {
                    Button("Back to canvas") { store.showingVariants = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if store.sourceURL != nil && !store.sourceAvailable {
                Text("The source image has moved, so the options cannot be rebuilt. Revert still restores the option you picked.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 14) {
                // The original, with the crop frame on it, in its own column:
                // every option is judged against it, and it is where the crop
                // is chosen. Not in the grid, because it is not an option.
                // Always this wide, image or not: a column that comes and goes
                // takes every option tile's size with it.
                VStack(spacing: 4) {
                    if let original = store.sourcePreview, let px = store.sourcePixels {
                        CropView(image: original, pixels: px, crop: store.crop,
                                 onChange: { store.setCrop($0) },
                                 onReset: { store.resetCrop() })
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text("Original")
                            .font(.system(size: 10, weight: .semibold))
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                .frame(width: 240)
                .help("Drag the frame to choose what gets reduced; drag a corner to resize; double-click to reset")
                ScrollView {
                    // 130 rather than 150: at the default window size that is
                    // the difference between four columns and three, and four
                    // fits the whole spread without scrolling.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(store.variants) { v in
                            Button { store.choose(v) } label: {
                                VStack(spacing: 4) {
                                    GridView(grid: v.grid, palette: v.palette)
                                        .aspectRatio(1, contentMode: .fit)
                                        .background(Color.primary.opacity(0.04))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(store.chosenVariant == v.id
                                                              ? Color.accentColor
                                                              : Color.primary.opacity(0.12),
                                                              lineWidth: store.chosenVariant == v.id ? 2 : 0.5)
                                        )
                                    Text(v.label)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// At zoom 0 the canvas fits the window; above that it renders at a fixed
    /// cell size inside a scroll view, because at 64 and 128 the cells get too
    /// small to hit reliably.
    @ViewBuilder
    private var canvas: some View {
        // The canvas shows every visible layer flattened; the tools write to the
        // active cel underneath it. That split is the whole of what layers are.
        let board = GridView(
            grid: store.visible,
            palette: store.palette,
            onDrag: { x, y, phase, erase in
                store.handleDrag(x: x, y: y, phase: phase, erase: erase)
            },
            preview: store.preview,
            previewIndex: store.selectedIndex,
            selection: store.selection,
            selectionMask: store.selectionMask,
            onionPrev: store.onionPrev,
            onionNext: store.onionNext,
            symmetry: store.symmetry,
            showGrid: store.showGrid,
            tiled: store.tiling
        )

        if store.zoom == 0 {
            board.aspectRatio(1, contentMode: .fit)
        } else {
            ScrollView([.horizontal, .vertical]) {
                let side = CGFloat(store.grid.count) * store.zoom * (store.tiling ? 3 : 1)
                board.frame(width: side, height: side)
            }
        }
    }

    private var toolBar: some View {
        HStack(spacing: 6) {
            Picker("", selection: $store.tool) {
                ForEach(CanvasStore.Tool.allCases) { t in
                    Image(systemName: t.symbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 262)
            .help(store.tool.label)
            .overlay {
                // Invisible buttons carrying the shortcuts, so B/G/I and the
                // rest work the way they do in every other pixel editor.
                HStack(spacing: 0) {
                    ForEach(CanvasStore.Tool.allCases) { t in
                        Button("") { store.tool = t }
                            .keyboardShortcut(t.key, modifiers: [])
                            .opacity(0)
                            .frame(width: 0, height: 0)
                    }
                }
            }

            if store.tool == .rect || store.tool == .ellipse {
                Toggle("Filled", isOn: $store.fillShapes)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }

            // Symmetry is a drawing mode, so it belongs beside the tools rather
            // than in a panel section of its own. Tinted while it is on, because
            // a mirroring brush you have forgotten about is a nasty surprise.
            Menu {
                Picker("", selection: $store.symmetry) {
                    ForEach(CanvasStore.Symmetry.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            } label: {
                Image(systemName: store.symmetry == .off
                      ? "circle.lefthalf.filled" : "circle.lefthalf.filled.righthalf.striped.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(store.symmetry == .off ? Color.primary : Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Symmetry: mirrors every stroke as you draw it. Brush and shapes, not fill.")

            // Effects change the cells themselves, so they belong with the tools
            // rather than in the Look menu, which is all render-only.
            if !store.effects.isEmpty {
                Menu {
                    Button("Gradient fill…") { store.openGradient() }
                    Divider()
                    ForEach(store.effects) { e in
                        Button(e.name) { store.applyEffect(e.id) }
                            .help(e.note)
                    }
                } label: {
                    Image(systemName: "wand.and.stars").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(store.isEmpty)
                .help("Effects — these rewrite the cells of this layer and add the colours they need to the palette. Undoable.")
            }

            Spacer()

            // Which layer the next stroke lands on, next to the canvas rather
            // than only in the timeline gutter. "Where did my drawing go" is
            // always this question.
            Text(store.frames.isEmpty ? " " : positionLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            smallButton("Fit", systemImage: "arrow.down.right.and.arrow.up.left") { store.zoom = 0 }
            smallButton("−", systemImage: "minus.magnifyingglass") {
                store.zoom = store.zoom == 0 ? 8 : max(2, store.zoom - 2)
            }
            smallButton("+", systemImage: "plus.magnifyingglass") {
                store.zoom = store.zoom == 0 ? 12 : min(40, store.zoom + 2)
            }
        }
    }

    /// Shown when picking an option would discard work. Offers a way out that
    /// keeps it, because "are you sure" with no escape is not a choice.
    private func replaceConfirm(_ v: CanvasStore.Variant) -> some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                Text("Replace this project?")
                    .font(.system(size: 13, weight: .semibold))
                Text("Loading “\(v.label)” starts again from one frame, discarding \(store.frames.count) frame\(store.frames.count == 1 ? "" : "s") and every edit. There is no undo across it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    smallButton("Save first", systemImage: "square.and.arrow.down", alwaysEnabled: true) {
                        store.save()
                    }
                    Spacer()
                    smallButton("Cancel", systemImage: "xmark", alwaysEnabled: true) { store.cancelPending() }
                    smallButton("Replace", systemImage: "arrow.triangle.2.circlepath", alwaysEnabled: true) {
                        store.confirmPending()
                    }
                }
            }
            .padding(16)
            .frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
        }
    }

    private var sourceHeader: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if hiddenLayers > 0 {
                        Label("\(hiddenLayers) layer\(hiddenLayers == 1 ? "" : "s") hidden",
                              systemImage: "eye.slash.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help("Hidden layers are not drawn on the canvas and are left out of exports. The eye in the timeline turns them back on.")
                    }
                }
            }
            Spacer(minLength: 0)
            if !store.variants.isEmpty && !store.showingVariants {
                headerButton("Options", "square.grid.2x2") { store.showOptions() }
            }
            headerButton("Open", "folder") { store.chooseFile() }
                .keyboardShortcut("o", modifiers: .command)
            headerButton("Save", "square.and.arrow.down") { store.save() }
                .keyboardShortcut("s", modifiers: .command)
        }
    }

    private func headerButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var positionLabel: String {
        var s = "Frame \(store.currentFrame + 1) of \(store.frames.count)"
        if store.layers.count > 1, store.layers.indices.contains(store.currentLayer) {
            s += "  ·  \(store.layers[store.currentLayer].name)"
        }
        return s
    }

    private var title: String {
        if let p = store.projectURL { return p.deletingPathExtension().lastPathComponent }
        return store.sourceURL?.lastPathComponent ?? "Untitled"
    }

    private var hiddenLayers: Int { store.layers.filter { !$0.visible }.count }

    private var subtitle: String {
        var parts: [String] = []
        if let s = store.sourceSize {
            parts.append("\(Int(s.width))×\(Int(s.height)) → \(store.gridSize)×\(store.gridSize)")
        } else if !store.isEmpty {
            parts.append("\(store.size)×\(store.size)")
        } else {
            return "Drop an image or a .\(ProjectFile.ext), or press Cmd+O"
        }
        if store.frames.count > 1 { parts.append("\(store.frames.count) frames") }
        if store.isDirty { parts.append("unsaved") }
        return parts.joined(separator: "  ·  ")
    }

    /// Clickable, because "drop a file here" is not a discoverable instruction
    /// on its own and the menu bar is where affordances go to hide.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Button { store.chooseFile() } label: {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("Drop an image or a project here, or click to choose")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Start a blank 48×48 canvas") { store.newDocument() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Controls

    /// Two sections when you are editing, and that is deliberate.
    ///
    /// Everything that used to live here as well (undo, redo, revert, copy,
    /// paste, clear, export, the roll arrows) already had a menu item and a
    /// keyboard shortcut. Duplicating them into the panel was meant to make them
    /// discoverable and instead turned the column into furniture you scroll past
    /// to reach the palette. The paragraphs of explanation went the same way,
    /// into tooltips.
    private var controlsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.showingVariants {
                    // Only the import controls while picking. The palette panel
                    // used to belong here, when options were built from a chosen
                    // palette; every option now carries its own, so it showed a
                    // palette that had nothing to do with what was on screen.
                    importControls
                } else {
                    paletteControls
                    animationControls
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var importControls: some View {
        Group {
            section("Grid") {
                Picker("", selection: $store.gridSize) {
                    ForEach(CanvasStore.sizes, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("The frame on the original is what gets reduced: drag to move it, drag a corner to resize, double-click to reset.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text("These build the options on the left. Picking one starts a new project from a single frame.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var animationControls: some View {
        section("Animation — \(Int(store.fps)) fps") {
            Slider(value: $store.fps, in: 1...24, step: 1)
                .help("Playback and GIF speed")
            HStack(spacing: 12) {
                Stepper(value: holdBinding, in: 1...8) {
                    Text("Hold ×\(store.frames.indices.contains(store.currentFrame) ? store.frames[store.currentFrame].hold : 1)")
                        .font(.system(size: 11, design: .monospaced))
                }
                .disabled(store.isEmpty)
                .help("How many ticks this frame is held for, in playback and in the GIF")

                Toggle("Onion", isOn: $store.onionSkin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Tints only the cells that differ from the neighbouring frames: orange for frames before, blue for frames after, fainter the further away. Drawing them whole would wash the canvas, because index 0 is an opaque white.")

                if store.onionSkin {
                    Stepper(value: $store.onionRange, in: 1...3) {
                        Text("±\(store.onionRange)")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .help("How many frames either side the onion skin shows")
                }
            }
        }
    }

    private var holdBinding: Binding<Int> {
        Binding(
            get: { store.frames.indices.contains(store.currentFrame)
                   ? store.frames[store.currentFrame].hold : 1 },
            set: { store.setHold($0) }
        )
    }


    /// Five rows became three. `From image` moved into the palette menu, which
    /// is where you choose a palette anyway, and its colour count went with it
    /// rather than sitting in the panel as a number with no visible subject.
    private var paletteControls: some View {
        section("Palette") {
            Menu {
                ForEach(Palettes.all) { p in
                    Button(p.name) { store.palette = p }
                }
                if let e = store.extracted, !Palettes.all.contains(e) {
                    Button(e.name) { store.palette = e }
                }
                Divider()
                Menu("From image") {
                    ForEach([4, 8, 16, 32], id: \.self) { n in
                        Button("\(n) colours") {
                            store.extractCount = n
                            store.extractPalette()
                        }
                    }
                }
                .disabled(!store.sourceAvailable)
            } label: {
                Text(store.palette.name).font(.system(size: 11)).lineLimit(1)
            }
            // The system pull-down look, not a hand-drawn one: borderlessButton
            // strips the chrome and moves the indicator to the left, so it stops
            // reading as something you can press.
            .controlSize(.small)
            .help("Switching palette remaps every frame to the nearest colour rather than re-importing, so your edits survive it.")

            PaletteStrip(
                palette: store.palette,
                usage: store.usage,
                selected: $store.selectedIndex,
                onReplace: { store.replaceColour(at: $0, with: $1) },
                onRemove: { store.removeColour(at: $0) },
                onSwap: { store.swapColour(from: $0, to: $1) },
                onShade: { store.addShade(of: $0, darker: $1) },
                onStartFrom: { store.startFrom($0) },
                draft: hex(store.draftColour)
            )
            .help("The number on each swatch is how many cells use it. Right-click for the same actions as the buttons below.")

            HStack(spacing: 5) {
                ColorPicker("", selection: $store.draftColour, supportsOpacity: false)
                    .labelsHidden()
                    .help("The colour Add and Replace use")

                // Shading, from the selected swatch. A menu because it is
                // three related things and the row has no room for three.
                Menu {
                    Button("Add Darker Shade") { store.addShade(of: store.selectedIndex, darker: true) }
                    Button("Add Lighter Shade") { store.addShade(of: store.selectedIndex, darker: false) }
                    Divider()
                    Button("Start a New Colour from This") { store.startFrom(store.selectedIndex) }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 11))
                        .frame(width: 26, height: 22)
                        .background(Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(store.selectedIndex < 0)
                .help("Shade the selected swatch: add a darker or lighter step, or put it in the colour well to adjust by hand.")

                iconButton("plus", "Add this colour as a new swatch. Nothing on the canvas changes.") {
                    store.addColour(hex(store.draftColour))
                }
                iconButton("arrow.left.arrow.right",
                           "Replace the selected swatch with this colour. Every cell using it changes colour; none of them move.") {
                    store.replaceColour(at: store.selectedIndex, with: hex(store.draftColour))
                }
                .disabled(store.selectedIndex < 0)
                .opacity(store.selectedIndex < 0 ? 0.4 : 1)

                // A menu rather than a button: a swap needs a destination,
                // and the destination is another swatch, not the colour well.
                Menu {
                    ForEach(Array(store.palette.colors.enumerated()), id: \.offset) { j, other in
                        if j != store.selectedIndex {
                            Button("\(j) — \(other)") { store.swapColour(from: store.selectedIndex, to: j) }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 11))
                        .frame(width: 26, height: 22)
                        .background(Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(store.selectedIndex < 0 || (store.usage[store.selectedIndex] ?? 0) == 0)
                .opacity(store.selectedIndex < 0 || (store.usage[store.selectedIndex] ?? 0) == 0 ? 0.4 : 1)
                .help("Send every cell of the selected colour to another swatch, in every frame and layer.")

                iconButton("minus",
                           "Remove the selected swatch. Whatever used it merges into the nearest remaining colour.") {
                    store.removeColour(at: store.selectedIndex)
                }
                .disabled(store.selectedIndex < 0 || store.palette.colors.count <= 2)
                .opacity(store.selectedIndex < 0 || store.palette.colors.count <= 2 ? 0.4 : 1)
            }
        }
    }

    private var scrollBuilder: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Roll across frames")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 6) {
                Text("Direction").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                ForEach(CanvasStore.RollDirection.allCases) { d in
                    Button { store.rollDirection = d } label: {
                        Image(systemName: d.symbol)
                            .font(.system(size: 11, weight: store.rollDirection == d ? .bold : .regular))
                            .frame(width: 32, height: 22)
                            .background(store.rollDirection == d
                                        ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Stepper(value: $store.rollStep, in: 1...8) {
                    Text("×\(store.rollStep)").font(.system(size: 11, design: .monospaced))
                }
            }

            Picker("", selection: $store.rollMode) {
                ForEach(CanvasStore.RollMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                Text("Frames").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                Stepper(value: $store.rollFrames, in: 2...96) {
                    Text("\(store.rollFrames)").font(.system(size: 11, design: .monospaced))
                }
                Spacer()
                smallButton("Full turn", systemImage: "arrow.triangle.2.circlepath", alwaysEnabled: true) {
                    store.rollMode = .loop
                    store.rollFrames = max(2, min(96, store.size / max(1, store.rollStep)))
                }
            }

            Text(scrollBuilderNote)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                smallButton("Cancel", systemImage: "xmark", alwaysEnabled: true) {
                    store.showingScrollBuilder = false
                }
                smallButton("Build \(store.rollFrames) frames", systemImage: "film.stack",
                            alwaysEnabled: true) { store.buildScroll() }
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    /// Says out loud whether the loop will actually close, rather than letting
    /// you find out by watching it jump.
    private var scrollBuilderNote: String {
        let travel = store.rollFrames * store.rollStep
        if store.rollMode == .backAndForth {
            return "Out and back, returning to where it started. Loops at any frame count. Replaces the animation; one undo."
        }
        if travel == store.size {
            return "Carries the picture exactly once round, so the loop closes seamlessly. Replaces the animation; one undo."
        }
        let n = max(2, store.size / max(1, store.rollStep))
        return "Travels \(travel) cells of \(store.size), so the loop will jump. \(n) frames would close it."
    }

    /// SwiftUI hands back a `Color`; the palette speaks hex. Converted through
    /// sRGB explicitly, because a Color carries a colour space and the default
    /// conversion can drift the value you actually picked.
    private func hex(_ c: Color) -> String {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .red
        return String(format: "#%02x%02x%02x",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }

    private func iconButton(_ symbol: String, _ help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .background(Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Gradient fill. A sheet rather than a drag tool: the two ends are colours
    /// rather than points, and a drag would only give you the direction, which
    /// is the least interesting of the four things you have to choose.
    private var gradientSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gradient fill")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 10) {
                ColorPicker("", selection: $store.gradFrom, supportsOpacity: false)
                    .labelsHidden()
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                ColorPicker("", selection: $store.gradTo, supportsOpacity: false)
                    .labelsHidden()
                Spacer()
                Text(hex(store.gradFrom) + " → " + hex(store.gradTo))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: $store.gradMode) {
                ForEach(CanvasStore.GradientMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                Text("Bands").font(.system(size: 11)).foregroundStyle(.secondary)
                Stepper(value: $store.gradBands, in: 2...32) {
                    Text("\(store.gradBands)").font(.system(size: 11, design: .monospaced))
                }
                Toggle("Dither", isOn: $store.gradDither)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("A 4×4 checkerboard between bands. Trades a colour for a texture, which is how pixel art has always softened a ramp.")
            }

            Text(gradientNote)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                smallButton("Cancel", systemImage: "xmark", alwaysEnabled: true) {
                    store.showingGradient = false
                }
                smallButton("Fill", systemImage: "paintbrush.fill", alwaysEnabled: true) {
                    store.applyGradient(from: hex(store.gradFrom), to: hex(store.gradTo))
                }
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private var gradientNote: String {
        let where_ = store.selection == nil
            ? "the whole of \(store.layers.indices.contains(store.currentLayer) ? store.layers[store.currentLayer].name : "this layer")"
            : "the selection"
        return "Fills \(where_). Adds up to \(store.gradBands) colours to the palette; "
             + "nothing already on the canvas changes. One undo."
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            content()
        }
    }

    /// The family's button primitive: an SF Symbol and a label at 11pt with a
    /// faint fill, because the same combination was otherwise repeated per button.
    private func smallButton(_ title: String, systemImage: String,
                             alwaysEnabled: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!alwaysEnabled && store.isEmpty)
        .opacity(!alwaysEnabled && store.isEmpty ? 0.4 : 1)
    }

    // MARK: - Drop

    private func loadFirst(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                guard store.confirmDiscard() else { return }
                store.openAny(url)
            }
        }
        return true
    }
}
