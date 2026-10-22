import SwiftUI

/// The original image with the square that gets reduced drawn on it.
///
/// Drag inside the frame to move it, drag a corner to resize it (it stays
/// square, pivoting on the opposite corner), double-click to go back to the
/// default. The frame follows the pointer live; `onChange` fires once, on
/// release, because every change rebuilds the whole spread of options.
///
/// Coordinates: `crop` is [left, top, side] in source *pixels*, which is what
/// the daemon crops by. The view maps to and from its own points through one
/// scale and offset, computed from `pixels`, not from the NSImage's size in
/// points, which differs for images carrying a DPI.
struct CropView: View {
    let image: NSImage
    let pixels: CGSize
    let crop: [Int]?
    var onChange: ([Int]) -> Void
    var onReset: () -> Void

    /// The frame while a drag is in progress, in pixels. Nil when idle.
    @State private var live: CGRect?
    @State private var mode: Mode?

    private enum Mode { case move(CGRect), resize(anchor: CGPoint) }

    var body: some View {
        GeometryReader { geo in
            let fit = fitting(in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.size.width, height: fit.size.height)
                    .offset(x: fit.origin.x, y: fit.origin.y)

                if let box = live ?? cropRect {
                    let r = toView(box, fit)
                    // Dim everything outside the frame: what is dimmed is thrown away.
                    Path { p in
                        p.addRect(fit)
                        p.addRect(r)
                    }
                    .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                    Rectangle()
                        .stroke(Color.white, lineWidth: 1.5)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                    ForEach(0..<4, id: \.self) { i in
                        // Inside the frame, not centred on its corners: on the
                        // corner, half of each knob sits outside the frame, and
                        // outside the tile too whenever the frame reaches the
                        // image's edge, where the tile's rounded clip ate it.
                        let c = knob(i, of: r)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white)
                            .frame(width: 9, height: 9)
                            .shadow(radius: 1)
                            .offset(x: c.x - 4.5, y: c.y - 4.5)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onReset() }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in drag(v, fit) }
                    .onEnded { _ in
                        if let r = live {
                            onChange([Int(r.minX.rounded()), Int(r.minY.rounded()), Int(r.width.rounded())])
                        }
                        live = nil; mode = nil
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var cropRect: CGRect? {
        guard let c = crop, c.count == 3 else { return nil }
        return CGRect(x: c[0], y: c[1], width: c[2], height: c[2])
    }

    // MARK: - Geometry

    /// Where the image sits inside the view, aspect-fit.
    private func fitting(in size: CGSize) -> CGRect {
        guard pixels.width > 0, pixels.height > 0 else { return CGRect(origin: .zero, size: size) }
        let k = min(size.width / pixels.width, size.height / pixels.height)
        let w = pixels.width * k, h = pixels.height * k
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func scale(_ fit: CGRect) -> CGFloat { fit.width / max(pixels.width, 1) }

    private func toView(_ r: CGRect, _ fit: CGRect) -> CGRect {
        let k = scale(fit)
        return CGRect(x: fit.minX + r.minX * k, y: fit.minY + r.minY * k, width: r.width * k, height: r.height * k)
    }

    private func toPixels(_ p: CGPoint, _ fit: CGRect) -> CGPoint {
        let k = scale(fit)
        return CGPoint(x: (p.x - fit.minX) / k, y: (p.y - fit.minY) / k)
    }

    /// A handle's centre: its corner, pulled toward the middle far enough that
    /// the whole knob is inside the frame. Never past a third of the frame, so
    /// a small selection's knobs cannot swap sides.
    private func knob(_ i: Int, of r: CGRect) -> CGPoint {
        let d = min(5.5, r.width / 3)
        let c = corner(i, of: r)
        return CGPoint(x: c.x + (c.x == r.minX ? d : -d), y: c.y + (c.y == r.minY ? d : -d))
    }

    private func corner(_ i: Int, of r: CGRect) -> CGPoint {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)][i]
    }

    // MARK: - Dragging

    private func drag(_ v: DragGesture.Value, _ fit: CGRect) {
        guard let start = cropRect else { return }
        if mode == nil {
            // A corner if the drag began within reach of one, else a move.
            let rv = toView(start, fit)
            if let i = (0..<4).first(where: {
                let c = knob($0, of: rv)
                return hypot(c.x - v.startLocation.x, c.y - v.startLocation.y) < 14
            }) {
                mode = .resize(anchor: corner(3 - i, of: start))
            } else if rv.insetBy(dx: -4, dy: -4).contains(v.startLocation) {
                mode = .move(start)
            } else {
                return
            }
        }
        let k = scale(fit)
        switch mode {
        case .move(let from):
            var r = from.offsetBy(dx: v.translation.width / k, dy: v.translation.height / k)
            r.origin.x = min(max(r.minX, 0), pixels.width - r.width)
            r.origin.y = min(max(r.minY, 0), pixels.height - r.height)
            live = r
        case .resize(let a):
            // Square, pivoting on the opposite corner, the larger of the two
            // extents so the frame follows the pointer diagonally, and never
            // past the image's edge on the side it grows toward.
            let p = toPixels(v.location, fit)
            let dx = p.x - a.x, dy = p.y - a.y
            let room = min(dx >= 0 ? pixels.width - a.x : a.x, dy >= 0 ? pixels.height - a.y : a.y)
            let side = min(max(abs(dx), abs(dy), 8), room)
            live = CGRect(x: dx >= 0 ? a.x : a.x - side, y: dy >= 0 ? a.y : a.y - side,
                          width: side, height: side)
        case nil:
            break
        }
    }
}
