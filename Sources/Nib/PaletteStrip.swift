import SwiftUI

/// The palette as swatches: the colour picker, and the pixel census.
///
/// Counts are the quickest read on whether a palette suits a subject. Six greys
/// spreading 350 pixels across four mid-tones is a halo; two colours splitting
/// 891/133 is an edge.
struct PaletteStrip: View {
    let palette: Palette
    let usage: [Int: Int]
    @Binding var selected: Int
    var onReplace: (Int, String) -> Void
    var onRemove: (Int) -> Void
    var onSwap: (Int, Int) -> Void
    var onShade: (Int, Bool) -> Void
    var onStartFrom: (Int) -> Void
    /// What the colour well is holding, so the menu items can name it.
    var draft: String = "#ff0000"

    private let columns = [GridItem(.adaptive(minimum: 26, maximum: 26), spacing: 5)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
            ForEach(Array(palette.colors.enumerated()), id: \.offset) { idx, hex in
                Button {
                    selected = idx
                } label: {
                    swatch(idx: idx, hex: hex)
                }
                .buttonStyle(.plain)
                .help("\(idx): \(hex) — \(usage[idx] ?? 0) px")
                .contextMenu {
                    if (usage[idx] ?? 0) > 0 {
                        Menu("Change all \(usage[idx] ?? 0) cells to") {
                            ForEach(Array(palette.colors.enumerated()), id: \.offset) { j, other in
                                if j != idx {
                                    Button("\(j) — \(other)") { onSwap(idx, j) }
                                }
                            }
                        }
                        Divider()
                    }
                    Button("Add Darker Shade") { onShade(idx, true) }
                    Button("Add Lighter Shade") { onShade(idx, false) }
                    Button("Start a New Colour from This") { onStartFrom(idx) }
                    Divider()
                    Button("Replace with \(draft)") { onReplace(idx, draft) }
                    Button("Remove \(hex)", role: .destructive) { onRemove(idx) }
                        .disabled(palette.colors.count <= 2)
                }
            }

            Button {
                selected = -1
            } label: {
                eraser
            }
            .buttonStyle(.plain)
            .help("Erase to transparent — \(usage[-1] ?? 0) px")
        }
    }

    private func swatch(idx: Int, hex: String) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Palettes.color(hex))
            .frame(width: 26, height: 26)
            .overlay(ring(active: selected == idx))
            .overlay(alignment: .bottomTrailing) { count(usage[idx]) }
    }

    private var eraser: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .frame(width: 26, height: 26)
            .overlay(
                Image(systemName: "eraser")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            )
            .overlay(ring(active: selected == -1))
    }

    private func ring(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(
                active ? Color.accentColor : Color.primary.opacity(0.15),
                lineWidth: active ? 2 : 0.5
            )
    }

    @ViewBuilder
    private func count(_ n: Int?) -> some View {
        if let n, n > 0 {
            Text(n >= 1000 ? "\(n / 1000)k" : "\(n)")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 2)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(1)
        }
    }
}
