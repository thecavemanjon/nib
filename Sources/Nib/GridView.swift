import SwiftUI

/// Renders a palette-indexed grid, and reports drags over it.
///
/// Drawn with `Canvas` rather than a stack of Rectangles because a 64x64 grid is
/// 4,096 views and SwiftUI charges for every one of them on each slider tick.
/// The cost of that choice is that hit-testing is arithmetic rather than free,
/// which `cell(at:in:)` does.
///
/// It knows nothing about tools. It reports where the pointer went and in which
/// phase, and the store decides what that means; the shape preview it draws is
/// handed to it already computed, by the same function that commits the shape.
struct GridView: View {
    let grid: [[Int]]
    let palette: Palette
    /// Nil makes the canvas read-only. Called with grid coordinates.
    var onDrag: ((Int, Int, CanvasStore.DragPhase, Bool) -> Void)?

    var preview: Set<Cell> = []
    var previewIndex: Int = -1
    var selection: CellRect?
    /// A lasso's cells. When set, the outline follows them instead of the box.
    var selectionMask: Set<Cell>?
    /// Nearest frame first. Each is drawn fainter the further away it is.
    var onionPrev: [[[Int]]] = []
    var onionNext: [[[Int]]] = []
    var symmetry: CanvasStore.Symmetry = .off
    var showGrid = false
    /// Draw eight copies around the canvas, so a seam in something meant to
    /// wrap shows up while you draw rather than in an exported GIF.
    var tiled = false

    @State private var stroking = false
    @Environment(\.colorScheme) private var scheme

    /// Opaque, and keyed to the grid rather than a fixed 8pt. This used to be a
    /// 14%-opacity grey painted over the window's vibrancy, which meant an empty
    /// cell and a white one looked near enough identical -- and with the Mono
    /// palette, white *is* a colour you can paint with.
    private var chequer: (light: Color, dark: Color) {
        scheme == .dark ? (Color(white: 0.17), Color(white: 0.25))
                        : (Color(white: 0.90), Color(white: 0.79))
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let n = grid.count
                guard n > 0 else { return }
                let g = geometry(n: n, in: size)

                if tiled { drawTiles(&ctx, n: n, g: g) }

                drawChequerboard(&ctx, origin: g.origin, side: g.cell * CGFloat(n), cell: g.cell)

                for (y, row) in grid.enumerated() {
                    for (x, idx) in row.enumerated() {
                        guard idx >= 0, idx < palette.colors.count else { continue }
                        ctx.fill(Path(rect(x, y, g)), with: .color(Palettes.color(palette.colors[idx])))
                    }
                }

                if showGrid { drawGridLines(&ctx, n: n, g: g) }

                // Onion skin: only the cells that differ from this frame, tinted
                // rather than drawn in their own colours. See CanvasStore.onionPrev.
                // Farthest first, so the nearest frame's tint lands on top.
                for (d, other) in onionPrev.enumerated().reversed() {
                    drawOnion(&ctx, other, tint: .orange, opacity: onionOpacity(d), g: g)
                }
                for (d, other) in onionNext.enumerated().reversed() {
                    drawOnion(&ctx, other, tint: .blue, opacity: onionOpacity(d), g: g)
                }

                for c in preview {
                    guard c.x >= 0, c.x < n, c.y >= 0, c.y < n else { continue }
                    let colour = previewIndex >= 0 && previewIndex < palette.colors.count
                        ? Palettes.color(palette.colors[previewIndex])
                        : Color.accentColor
                    ctx.fill(Path(rect(c.x, c.y, g)), with: .color(colour.opacity(0.75)))
                }

                if symmetry != .off {
                    let side = g.cell * CGFloat(n)
                    var axes = Path()
                    if symmetry == .vertical || symmetry == .both {
                        axes.move(to: CGPoint(x: g.origin.x + side / 2, y: g.origin.y))
                        axes.addLine(to: CGPoint(x: g.origin.x + side / 2, y: g.origin.y + side))
                    }
                    if symmetry == .horizontal || symmetry == .both {
                        axes.move(to: CGPoint(x: g.origin.x, y: g.origin.y + side / 2))
                        axes.addLine(to: CGPoint(x: g.origin.x + side, y: g.origin.y + side / 2))
                    }
                    ctx.stroke(axes, with: .color(.accentColor.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }

                // The board's own edge. Without it a sprite with transparent
                // margins has no visible boundary at all. When tiled it is the
                // only thing saying which copy is the one you are drawing on.
                ctx.stroke(Path(CGRect(x: g.origin.x, y: g.origin.y,
                                       width: g.cell * CGFloat(n), height: g.cell * CGFloat(n))),
                           with: .color(tiled ? .accentColor : .primary.opacity(0.18)),
                           lineWidth: tiled ? 1.5 : 1)

                if let s = selection {
                    let outline: Path
                    if let mask = selectionMask {
                        outline = edges(of: mask, g: g)
                    } else {
                        outline = Path(CGRect(
                            x: g.origin.x + CGFloat(s.x0) * g.cell,
                            y: g.origin.y + CGFloat(s.y0) * g.cell,
                            width: CGFloat(s.width) * g.cell,
                            height: CGFloat(s.height) * g.cell
                        ))
                    }
                    // Two passes, offset dashes: a single dashed stroke vanishes
                    // against whichever of black or white it happens to land on.
                    ctx.stroke(outline, with: .color(.white),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    ctx.stroke(outline, with: .color(.black),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4], dashPhase: 4))
                }
            }
            .contentShape(Rectangle())
            // Only install the gestures when this canvas is editable. A
            // read-only GridView -- every thumbnail in the import picker and
            // every frame in the filmstrip is one -- still consumed the tap, so
            // the Button wrapping it never fired and nothing could be chosen.
            .allowsHitTesting(onDrag != nil)
            .gesture(
                // minimumDistance 0 so a plain click paints one pixel. A single
                // DragGesture handles click and drag together here because the
                // canvas is one view; per-cell views with their own gestures is
                // the arrangement that silently fails.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in report(value.location, in: geo.size, erase: false) }
                    .onEnded { value in finish(value.location, in: geo.size, erase: false) }
            )
            .simultaneousGesture(
                // Option-drag erases to transparent.
                DragGesture(minimumDistance: 0)
                    .modifiers(.option)
                    .onChanged { value in report(value.location, in: geo.size, erase: true) }
                    .onEnded { value in finish(value.location, in: geo.size, erase: true) }
            )
        }
    }

    // MARK: - Drawing

    private func rect(_ x: Int, _ y: Int, _ g: (origin: CGPoint, cell: CGFloat)) -> CGRect {
        // Nudged out by a hair so neighbours never leave a seam of background
        // showing at fractional scales.
        CGRect(x: g.origin.x + CGFloat(x) * g.cell,
               y: g.origin.y + CGFloat(y) * g.cell,
               width: g.cell + 0.5, height: g.cell + 0.5)
    }

    /// 0.32 for the neighbouring frame, as it always was, then fading, so a
    /// trail of three reads as a trail and not as three equal ghosts.
    private func onionOpacity(_ distance: Int) -> Double {
        [0.32, 0.18, 0.10][min(distance, 2)]
    }

    private func drawOnion(_ ctx: inout GraphicsContext, _ other: [[Int]], tint: Color,
                           opacity: Double, g: (origin: CGPoint, cell: CGFloat)) {
        for (y, row) in other.enumerated() {
            guard y < grid.count else { break }
            for (x, idx) in row.enumerated() {
                // Only where the other frame has something: tinting cells it
                // leaves empty painted over the current frame's own drawing,
                // and with three frames each side it vanished under six tints.
                guard idx >= 0, x < grid[y].count, grid[y][x] != idx else { continue }
                ctx.fill(Path(rect(x, y, g)), with: .color(tint.opacity(opacity)))
            }
        }
    }

    /// Lines between cells, with every eighth one heavier so a 64 can be
    /// counted in eights rather than ones. Skipped when cells are too small for
    /// lines to be anything but a grey wash over the art.
    private func drawGridLines(_ ctx: inout GraphicsContext, n: Int,
                               g: (origin: CGPoint, cell: CGFloat)) {
        guard g.cell >= 5 else { return }
        let side = g.cell * CGFloat(n)
        var minor = Path(), major = Path()
        for i in 1..<n {
            let o = CGFloat(i) * g.cell
            var p = i.isMultiple(of: 8) ? major : minor
            p.move(to: CGPoint(x: g.origin.x + o, y: g.origin.y))
            p.addLine(to: CGPoint(x: g.origin.x + o, y: g.origin.y + side))
            p.move(to: CGPoint(x: g.origin.x, y: g.origin.y + o))
            p.addLine(to: CGPoint(x: g.origin.x + side, y: g.origin.y + o))
            if i.isMultiple(of: 8) { major = p } else { minor = p }
        }
        ctx.stroke(minor, with: .color(.primary.opacity(0.10)), lineWidth: 0.5)
        ctx.stroke(major, with: .color(.primary.opacity(0.28)), lineWidth: 1)
    }

    /// The eight neighbours. One path per colour, filled once per tile: at 64
    /// drawing cell by cell would be 32,000 fills a frame, on every stroke.
    private func drawTiles(_ ctx: inout GraphicsContext, n: Int,
                           g: (origin: CGPoint, cell: CGFloat)) {
        let side = g.cell * CGFloat(n)
        var paths: [Int: Path] = [:]
        for (y, row) in grid.enumerated() {
            for (x, idx) in row.enumerated() where idx >= 0 && idx < palette.colors.count {
                paths[idx, default: Path()].addRect(
                    CGRect(x: CGFloat(x) * g.cell, y: CGFloat(y) * g.cell,
                           width: g.cell + 0.5, height: g.cell + 0.5))
            }
        }
        for ty in -1...1 {
            for tx in -1...1 where tx != 0 || ty != 0 {
                let o = CGPoint(x: g.origin.x + CGFloat(tx) * side, y: g.origin.y + CGFloat(ty) * side)
                drawChequerboard(&ctx, origin: o, side: side, cell: g.cell)
                var t = ctx
                t.translateBy(x: o.x, y: o.y)
                for (idx, p) in paths {
                    t.fill(p, with: .color(Palettes.color(palette.colors[idx])))
                }
            }
        }
    }

    /// Every cell side that borders an unselected cell: the lasso's outline,
    /// stepped along cell edges the way the selection actually is.
    private func edges(of mask: Set<Cell>, g: (origin: CGPoint, cell: CGFloat)) -> Path {
        var p = Path()
        for c in mask {
            let x = g.origin.x + CGFloat(c.x) * g.cell, y = g.origin.y + CGFloat(c.y) * g.cell
            let e = g.cell
            if !mask.contains(Cell(x: c.x, y: c.y - 1)) { p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + e, y: y)) }
            if !mask.contains(Cell(x: c.x, y: c.y + 1)) { p.move(to: CGPoint(x: x, y: y + e)); p.addLine(to: CGPoint(x: x + e, y: y + e)) }
            if !mask.contains(Cell(x: c.x - 1, y: c.y)) { p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + e)) }
            if !mask.contains(Cell(x: c.x + 1, y: c.y)) { p.move(to: CGPoint(x: x + e, y: y)); p.addLine(to: CGPoint(x: x + e, y: y + e)) }
        }
        return p
    }

    // MARK: - Geometry

    /// Where the editable copy sits. Tiled, the view holds three canvases
    /// across and the editable one is the middle.
    private func geometry(n: Int, in size: CGSize) -> (origin: CGPoint, cell: CGFloat) {
        let span = CGFloat(tiled ? 3 : 1)
        let cell = min(size.width, size.height) / (CGFloat(n) * span)
        let side = cell * CGFloat(n)
        let inset = tiled ? side : 0
        return (CGPoint(x: (size.width - side * span) / 2 + inset,
                        y: (size.height - side * span) / 2 + inset), cell)
    }

    private func cell(at point: CGPoint, in size: CGSize) -> Cell? {
        let n = grid.count
        guard n > 0 else { return nil }
        let g = geometry(n: n, in: size)
        let x = Int(floor((point.x - g.origin.x) / g.cell))
        let y = Int(floor((point.y - g.origin.y) / g.cell))
        // Clamped rather than dropped: dragging a shape or a selection past the
        // edge should keep tracking, not freeze at the last cell inside.
        return Cell(x: min(max(x, -1), n), y: min(max(y, -1), n))
    }

    private func report(_ point: CGPoint, in size: CGSize, erase: Bool) {
        guard let onDrag, let c = cell(at: point, in: size) else { return }
        if !stroking {
            stroking = true
            onDrag(c.x, c.y, .began, erase)
        } else {
            onDrag(c.x, c.y, .changed, erase)
        }
    }

    private func finish(_ point: CGPoint, in size: CGSize, erase: Bool) {
        guard let onDrag, let c = cell(at: point, in: size) else { return }
        if !stroking { onDrag(c.x, c.y, .began, erase) }
        stroking = false
        onDrag(c.x, c.y, .ended, erase)
    }

    private func drawChequerboard(_ ctx: inout GraphicsContext, origin: CGPoint,
                                  side: CGFloat, cell: CGFloat) {
        // One square per cell wherever the cells are big enough to see, so an
        // empty area reads as a grid of empty *cells* rather than as texture.
        let step = max(cell, 5)
        let (light, dark) = chequer
        var row = 0
        var y = origin.y
        while y < origin.y + side {
            var col = 0
            var x = origin.x
            while x < origin.x + side {
                let w = min(step, origin.x + side - x)
                let h = min(step, origin.y + side - y)
                ctx.fill(Path(CGRect(x: x, y: y, width: w, height: h)),
                         with: .color((row + col).isMultiple(of: 2) ? light : dark))
                x += step; col += 1
            }
            y += step; row += 1
        }
    }
}
