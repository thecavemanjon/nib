import SwiftUI

/// The look preview: this frame photographed through a screen.
///
/// A panel rather than a canvas mode, because the two things want opposite
/// treatment. The canvas is a grid of cells you edit; a look is sub-cell detail
/// -- roughly five phosphor triads per cell -- that cannot live in the grid at
/// all. Putting the filtered result back into a frame gets you a palette swap
/// and a slight blur, measured at 16.7/255 from a plain recolour. So the canvas
/// keeps showing what you are editing, and this shows what it will look like.
struct LookPreview: View {
    @EnvironmentObject private var store: CanvasStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $store.previewLook) {
                    ForEach(store.looks.filter { $0.filtered }) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 130)
                .onChange(of: store.previewLook) { Task { await store.renderPreview() } }

                if store.isPreviewing {
                    ProgressView().scaleEffect(0.45).frame(width: 14, height: 14)
                }
                Spacer()
                button("Recolour canvas", "paintpalette") { store.recolour(to: store.previewLook) }
                    .disabled(store.isEmpty || store.previewLook == "screen")
                    .opacity(store.previewLook == "screen" ? 0.4 : 1)
                    .help("Re-light the palette between this look's two colours, index for index. Nothing moves, and you carry on drawing in it. Screen has no colour of its own, so there is nothing to bake in.")
                button("Export", "square.and.arrow.down") {
                    store.export(scale: 16, look: store.previewLook)
                }
            }
            .padding(10)

            Divider()

            ZStack {
                Color.black
                if let img = store.previewImage {
                    // 1:1 in a scroll view, never scaled to fit. Downscaling a
                    // grille aliases it into wide rainbow bands, which makes a
                    // correct render look broken.
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: img)
                            .interpolation(.none)
                            .padding(12)
                    }
                } else {
                    Text(store.isEmpty ? "Nothing open" : "Rendering…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            Text("Shown at 1:1. The grille only exists at export size, so this is what a 512px export looks like — not what the canvas looks like.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 380)
        .onAppear { store.previewOpen = true }
        .onDisappear { store.previewOpen = false }
    }

    private func button(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(store.isEmpty)
        .opacity(store.isEmpty ? 0.4 : 1)
    }
}
