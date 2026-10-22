import SwiftUI

/// Frames across, layers down.
///
/// One region rather than a filmstrip plus a layers panel: layers and frames are
/// two axes of the same thing, and splitting them into separate lists is what
/// makes an editor feel cluttered. With a single layer the gutter is hidden
/// entirely and this is pixel-identical to the filmstrip it replaces, so the
/// complexity only appears once you have asked for it.
struct Timeline: View {
    @EnvironmentObject private var store: CanvasStore
    /// Which layer's name is being edited, if any. A row is a Text until you
    /// double-click it: an always-live TextField swallows the single click that
    /// is meant to select the layer, so clicking "Layer 1" put a caret in it and
    /// left you drawing on Layer 2.
    @State private var renaming: UUID?
    @FocusState private var nameFocused: Bool

    private let thumb: CGFloat = 46
    private let gutter: CGFloat = 96
    private let rowGap: CGFloat = 5
    /// Three rows before it starts scrolling. Beyond that the canvas suffers
    /// more than the timeline gains.
    private let maxRows = 3

    private var stacked: Bool { store.layers.count > 1 }
    private var rowH: CGFloat { thumb + rowGap }
    private var bodyH: CGFloat {
        let rows = min(max(store.layers.count, 1), maxRows)
        return CGFloat(rows) * rowH + (stacked ? 14 : 12)
    }

    /// Top of the stack first: `layers` is stored bottom-first because
    /// compositing wants a forward loop, and everyone expects the reverse.
    private var order: [Int] { Array(store.layers.indices).reversed() }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView(.vertical, showsIndicators: stacked) {
                HStack(alignment: .top, spacing: 0) {
                    if stacked {
                        VStack(alignment: .leading, spacing: rowGap) {
                            Color.clear.frame(height: 12)          // aligns with the number row
                            ForEach(order, id: \.self) { layerRow($0) }
                        }
                        .frame(width: gutter, alignment: .leading)
                    }

                    // One horizontal scroll wrapping every row, so the rows can
                    // never drift out of step with each other or with the numbers.
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: rowGap) {
                            numbers
                            ForEach(order, id: \.self) { l in
                                HStack(spacing: 5) {
                                    ForEach(Array(store.frames.enumerated()), id: \.element.id) { f, frame in
                                        cel(frame: f, layer: l)
                                    }
                                }
                            }
                        }
                        .padding(.trailing, 6)
                    }
                }
            }
            .frame(height: bodyH)

            Divider().frame(height: bodyH * 0.7)
            buttons
        }
        .frame(height: bodyH)
    }

    private var numbers: some View {
        HStack(spacing: 5) {
            ForEach(Array(store.frames.enumerated()), id: \.element.id) { i, frame in
                Text(frame.hold > 1 ? "\(i + 1) ×\(frame.hold)" : "\(i + 1)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(i == store.currentFrame ? Color.accentColor : .secondary)
                    .frame(width: thumb)
            }
        }
        .frame(height: 12)
    }

    private func layerRow(_ i: Int) -> some View {
        let hidden = !store.layers[i].visible
        return HStack(spacing: 5) {
            // Its own padded well with a divider after it. The eye used to sit
            // 16pt from the name inside the row you click to *select* a layer,
            // so reaching for the row hit the eye instead and the artwork
            // vanished with almost no signal that it had.
            Button { store.toggleLayerVisible(i) } label: {
                Image(systemName: hidden ? "eye.slash.fill" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(hidden ? Color.orange : Color.primary.opacity(0.75))
                    .frame(width: 24, height: thumb - 8)
                    .background(hidden ? Color.orange.opacity(0.18) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(hidden ? "This layer is hidden — click to show it" : "Hide this layer")

            Divider().frame(height: thumb - 14)

            if renaming == store.layers[i].id {
                TextField("", text: Binding(
                    get: { store.layers.indices.contains(i) ? store.layers[i].name : "" },
                    set: { store.renameLayer(i, to: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .focused($nameFocused)
                .onSubmit { renaming = nil }
                .onAppear { nameFocused = true }
                .onChange(of: nameFocused) { if !nameFocused { renaming = nil } }
            } else {
                Text(store.layers[i].name)
                    .font(.system(size: 11, weight: i == store.currentLayer ? .semibold : .regular))
                    .foregroundStyle(hidden ? Color.orange
                                            : (i == store.currentLayer ? Color.primary : .secondary))
                    .strikethrough(hidden)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: thumb, alignment: .leading)
        .background(i == store.currentLayer ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.selectLayer(i) }
        // Rename lives here rather than on a double-click. A double-tap gesture
        // alongside a single one makes SwiftUI wait out the double-click
        // interval before every single tap fires, so selecting a layer felt
        // sticky by about a quarter of a second.
        .contextMenu {
            Button("Rename \(store.layers[i].name)") {
                store.selectLayer(i)
                renaming = store.layers[i].id
            }
            Button(store.layers[i].visible ? "Hide" : "Show") { store.toggleLayerVisible(i) }
        }
        .help("Click to draw on this layer. Right-click to rename it.")
    }

    private func cel(frame f: Int, layer l: Int) -> some View {
        let isHere = f == store.currentFrame && l == store.currentLayer
        return Button {
            store.selectFrame(f)
            store.selectLayer(l)
        } label: {
            GridView(grid: store.frames[f].cels.indices.contains(l) ? store.frames[f].cels[l] : [],
                     palette: store.palette)
                .frame(width: thumb, height: thumb)
                .opacity(store.layers.indices.contains(l) && store.layers[l].visible ? 1 : 0.35)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isHere ? Color.accentColor : Color.primary.opacity(0.15),
                                      lineWidth: isHere ? 2 : 0.5)
                )
                // The whole thumbnail is the target. Without this the button
                // had nothing hittable in it: a timeline `GridView` is not
                // editable, so it turns its own hit testing off, and the
                // stroked border is a hairline. Clicks fell straight through
                // and the only way to change frame was the chevrons.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Frame \(f + 1), \(store.layers.indices.contains(l) ? store.layers[l].name : "layer")")
    }

    private var buttons: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 4) {
                icon("plus", "Add a blank frame") { store.addFrame() }
                icon("plus.square.on.square", "Duplicate this frame") { store.duplicateFrame() }
                icon("trash", "Delete this frame") { store.deleteFrame() }
                    .disabled(store.frames.count < 2)
                // Navigate. These are chevrons beside a filmstrip, so they were
                // always going to read as previous/next -- they reordered the
                // animation instead, which is a bad thing to do by accident.
                // Reordering is in the Frame menu.
                icon("chevron.left", "Previous frame") { store.selectFrame(store.currentFrame - 1) }
                    .disabled(store.currentFrame == 0)
                icon("chevron.right", "Next frame") { store.selectFrame(store.currentFrame + 1) }
                    .disabled(store.currentFrame >= store.frames.count - 1)
                icon(store.isPlaying ? "stop.fill" : "play.fill",
                     store.isPlaying ? "Stop" : "Play") { store.togglePlay() }
                    .disabled(store.frames.count < 2)
            }
            HStack(spacing: 4) {
                icon("square.stack.3d.up", "Add a layer above this one") { store.addLayer() }
                icon("square.stack.3d.up.slash", "Delete this layer") { store.deleteLayer() }
                    .disabled(store.layers.count < 2)
                icon("arrow.up", "Move this layer up the stack") { store.moveLayer(by: 1) }
                    .disabled(store.currentLayer >= store.layers.count - 1)
                icon("arrow.down", "Move this layer down the stack") { store.moveLayer(by: -1) }
                    .disabled(store.currentLayer == 0)
            }
        }
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 22, height: 20)
                .background(Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
