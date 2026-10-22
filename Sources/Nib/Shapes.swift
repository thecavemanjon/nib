import Foundation

/// A grid coordinate. Hashable so a shape can be a set: the rasterisers below
/// return every cell a shape touches, deduplicated, and the store stamps them
/// in one pass rather than drawing the same pixel four times.
struct Cell: Hashable {
    let x: Int
    let y: Int
}

/// An inclusive rectangle of cells, always normalised so `x0 <= x1`.
struct CellRect: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int

    init(_ a: Cell, _ b: Cell) {
        x0 = min(a.x, b.x); x1 = max(a.x, b.x)
        y0 = min(a.y, b.y); y1 = max(a.y, b.y)
    }

    init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }

    var width: Int { x1 - x0 + 1 }
    var height: Int { y1 - y0 + 1 }
    var count: Int { width * height }

    func contains(_ c: Cell) -> Bool { c.x >= x0 && c.x <= x1 && c.y >= y0 && c.y <= y1 }

    func offset(dx: Int, dy: Int) -> CellRect {
        CellRect(x0: x0 + dx, y0: y0 + dy, x1: x1 + dx, y1: y1 + dy)
    }

    /// Pull the rectangle inside an n-by-n grid, renormalising as it goes. A
    /// drag that ends past the right edge produces x0 > x1 otherwise, and a
    /// reversed range is a crash rather than an empty selection.
    func clamped(to n: Int) -> CellRect {
        guard n > 0 else { return CellRect(x0: 0, y0: 0, x1: 0, y1: 0) }
        let a = min(max(0, x0), n - 1), b = min(max(0, x1), n - 1)
        let c = min(max(0, y0), n - 1), d = min(max(0, y1), n - 1)
        return CellRect(x0: min(a, b), y0: min(c, d), x1: max(a, b), y1: max(c, d))
    }
}

/// Whole-grid operations. Pure, like `Shapes` below, and here for the same
/// reason: the preview and the commit must agree, and a generator building
/// twenty frames must produce exactly what rolling twenty times by hand would.
enum Grids {

    /// Shift the grid, wrapping at the edges: what leaves one side arrives at
    /// the other. This is the whole trick behind a scrolling background, and the
    /// reason a plain selection move cannot do it -- that pushes content off the
    /// edge and leaves transparency behind, losing a row every frame.
    static func rolled(_ grid: [[Int]], dx: Int, dy: Int) -> [[Int]] {
        let h = grid.count
        guard h > 0, let w = grid.first?.count, w > 0 else { return grid }
        let sy = ((dy % h) + h) % h
        let sx = ((dx % w) + w) % w
        guard sx != 0 || sy != 0 else { return grid }

        var out = grid
        for y in 0..<h {
            let src = grid[((y - sy) % h + h) % h]
            for x in 0..<w {
                out[y][x] = src[((x - sx) % w + w) % w]
            }
        }
        return out
    }

    enum Transform: String {
        case flipH = "Flip horizontal", flipV = "Flip vertical"
        case rotateCW = "Rotate clockwise", rotateCCW = "Rotate anticlockwise"
    }

    /// Marks a cell inside a selection's bounding box that is not selected.
    /// Never a palette index, and never -1, which is transparent and *is* content.
    static let outside = Int.min

    /// Flip or rotate the cells inside `rect`, returning the new grid and where
    /// the cells ended up. A rotation of a non-square rect turns about its
    /// centre, so it can poke past the old rect; there, transparent cells are
    /// not stamped, or rotating a sprite would punch holes in its neighbours.
    /// With a `mask` (a lasso), only those cells move, and the mask comes back
    /// transformed with them.
    static func transformed(_ grid: [[Int]], rect r: CellRect, mask: Set<Cell>? = nil,
                            _ t: Transform) -> (grid: [[Int]], rect: CellRect, mask: Set<Cell>?) {
        let n = grid.count
        guard n > 0 else { return (grid, r, mask) }
        let block = (r.y0...r.y1).map { y in
            (r.x0...r.x1).map { x in mask.map { $0.contains(Cell(x: x, y: y)) } ?? true ? grid[y][x] : outside }
        }
        let w = r.width, h = r.height
        let out: [[Int]]
        switch t {
        case .flipH:     out = block.map { $0.reversed() }
        case .flipV:     out = block.reversed()
        case .rotateCW:  out = (0..<w).map { x in (0..<h).map { y in block[h - 1 - y][x] } }
        case .rotateCCW: out = (0..<w).map { x in (0..<h).map { y in block[y][w - 1 - x] } }
        }
        let nw = out.first?.count ?? 0, nh = out.count
        let ox = r.x0 + (w - nw) / 2, oy = r.y0 + (h - nh) / 2

        var g = grid
        for y in r.y0...r.y1 {
            for x in r.x0...r.x1 where block[y - r.y0][x - r.x0] != outside { g[y][x] = -1 }
        }
        var moved: Set<Cell> = []
        for (dy, row) in out.enumerated() {
            for (dx, v) in row.enumerated() {
                let y = oy + dy, x = ox + dx
                guard v != outside, y >= 0, y < n, x >= 0, x < n else { continue }
                moved.insert(Cell(x: x, y: y))
                if v >= 0 { g[y][x] = v }
            }
        }
        return (g, CellRect(x0: ox, y0: oy, x1: ox + nw - 1, y1: oy + nh - 1),
                mask == nil ? nil : moved)
    }
}

extension Shapes {

    /// The cells a lasso encloses: the path itself, plus every cell whose centre
    /// is inside the polygon the path traces (closed back to its start). Even-odd,
    /// so a path that crosses itself leaves a hole where a person would expect one.
    static func lasso(_ path: [Cell], size n: Int) -> Set<Cell> {
        var cells = Set(path.filter { $0.x >= 0 && $0.x < n && $0.y >= 0 && $0.y < n })
        guard path.count > 2 else { return cells }
        let xs = path.map(\.x), ys = path.map(\.y)
        let x0 = max(0, xs.min()!), x1 = min(n - 1, xs.max()!)
        let y0 = max(0, ys.min()!), y1 = min(n - 1, ys.max()!)
        guard x0 <= x1, y0 <= y1 else { return cells }
        for y in y0...y1 {
            let py = Double(y) + 0.5
            for x in x0...x1 {
                let px = Double(x) + 0.5
                var inside = false
                var j = path.count - 1
                for i in path.indices {
                    let (ax, ay) = (Double(path[i].x) + 0.5, Double(path[i].y) + 0.5)
                    let (bx, by) = (Double(path[j].x) + 0.5, Double(path[j].y) + 0.5)
                    if (ay > py) != (by > py), px < (bx - ax) * (py - ay) / (by - ay) + ax {
                        inside.toggle()
                    }
                    j = i
                }
                if inside { cells.insert(Cell(x: x, y: y)) }
            }
        }
        return cells
    }

    /// Bounding box of a set of cells.
    static func bounds(_ cells: Set<Cell>) -> CellRect? {
        guard let first = cells.first else { return nil }
        var r = CellRect(first, first)
        for c in cells {
            r.x0 = min(r.x0, c.x); r.x1 = max(r.x1, c.x)
            r.y0 = min(r.y0, c.y); r.y1 = max(r.y1, c.y)
        }
        return r
    }
}

/// Shape rasterisers. Pure functions on cells: no palette, no grid, no store.
/// They are separate from the editor because a preview and a commit must draw
/// exactly the same cells, and the only way to guarantee that is to ask once.
enum Shapes {

    /// Bresenham. Also does the joining-up during a freehand drag: a fast mouse
    /// reports cells several apart, and without this the stroke comes out dotted.
    static func line(from a: Cell, to b: Cell) -> Set<Cell> {
        var out: Set<Cell> = []
        var x = a.x, y = a.y
        let dx = abs(b.x - a.x), dy = -abs(b.y - a.y)
        let sx = a.x < b.x ? 1 : -1, sy = a.y < b.y ? 1 : -1
        var err = dx + dy
        while true {
            out.insert(Cell(x: x, y: y))
            if x == b.x && y == b.y { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
        return out
    }

    static func rect(from a: Cell, to b: Cell, filled: Bool) -> Set<Cell> {
        let r = CellRect(a, b)
        var out: Set<Cell> = []
        if filled {
            for y in r.y0...r.y1 { for x in r.x0...r.x1 { out.insert(Cell(x: x, y: y)) } }
            return out
        }
        for x in r.x0...r.x1 { out.insert(Cell(x: x, y: r.y0)); out.insert(Cell(x: x, y: r.y1)) }
        for y in r.y0...r.y1 { out.insert(Cell(x: r.x0, y: y)); out.insert(Cell(x: r.x1, y: y)) }
        return out
    }

    /// Ellipse inscribed in the dragged box.
    ///
    /// Scanned twice, once per axis, and unioned. A single x-scan leaves gaps up
    /// the steep sides where one column spans several rows; scanning y as well
    /// fills exactly those, and the outline comes out connected at every aspect
    /// ratio. Cheap enough at these sizes to not care that it is two passes.
    static func ellipse(from a: Cell, to b: Cell, filled: Bool) -> Set<Cell> {
        let r = CellRect(a, b)
        let rx = Double(r.width - 1) / 2, ry = Double(r.height - 1) / 2
        let cx = Double(r.x0) + rx, cy = Double(r.y0) + ry
        if rx <= 0 || ry <= 0 { return line(from: a, to: b) }

        var out: Set<Cell> = []
        for x in r.x0...r.x1 {
            let t = (Double(x) - cx) / rx
            let dy = ry * (1 - t * t).squareRoot()
            if dy.isNaN { continue }
            let lo = Int((cy - dy).rounded()), hi = Int((cy + dy).rounded())
            if filled {
                for y in lo...hi { out.insert(Cell(x: x, y: y)) }
            } else {
                out.insert(Cell(x: x, y: lo)); out.insert(Cell(x: x, y: hi))
            }
        }
        if !filled {
            for y in r.y0...r.y1 {
                let t = (Double(y) - cy) / ry
                let dx = rx * (1 - t * t).squareRoot()
                if dx.isNaN { continue }
                out.insert(Cell(x: Int((cx - dx).rounded()), y: y))
                out.insert(Cell(x: Int((cx + dx).rounded()), y: y))
            }
        }
        return out
    }
}
