import AppKit
import UniformTypeIdentifiers

/// One layer, as the project sees it: a name, whether it is showing, and its
/// place in the stack. Deliberately holds no pixels.
///
/// Layers and frames form a grid of cels, and this is the row header. Keeping
/// the metadata here rather than on every frame means renaming a layer is one
/// write instead of one per frame, and a frame can never disagree with another
/// about how many layers exist.
struct LayerInfo: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var visible: Bool = true
}

/// One frame: a cel per layer, and how long it is held for.
///
/// `cels` runs bottom to top, parallel to the project's `layers`. Bottom-first
/// because compositing is then a plain forward loop; the timeline reverses it
/// for display, since people expect the top layer at the top.
struct Frame: Identifiable, Codable, Equatable {
    var id = UUID()
    var cels: [[[Int]]]
    var hold: Int = 1

    static func blank(size: Int, layers: Int) -> Frame {
        Frame(cels: Array(repeating: Array(repeating: Array(repeating: -1, count: size),
                                           count: size),
                          count: max(1, layers)))
    }

    /// Flatten to one grid: the topmost visible layer that has ink at each cell.
    func composite(_ layers: [LayerInfo]) -> [[Int]] {
        guard let base = cels.first else { return [] }
        var out = Array(repeating: Array(repeating: -1, count: base.first?.count ?? 0),
                        count: base.count)
        for (i, cel) in cels.enumerated() {
            guard i >= layers.count || layers[i].visible else { continue }
            for y in cel.indices {
                for x in cel[y].indices where cel[y][x] >= 0 {
                    out[y][x] = cel[y][x]
                }
            }
        }
        return out
    }

    // v1 wrote a single `grid`. Read it as a one-layer frame rather than
    // refusing to open files that were saved before layers existed.
    enum CodingKeys: String, CodingKey { case id, cels, hold, grid }

    init(id: UUID = UUID(), cels: [[[Int]]], hold: Int = 1) {
        self.id = id; self.cels = cels; self.hold = hold
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        hold = (try? c.decode(Int.self, forKey: .hold)) ?? 1
        if let cels = try? c.decode([[[Int]]].self, forKey: .cels) {
            self.cels = cels
        } else {
            self.cels = [try c.decode([[Int]].self, forKey: .grid)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(cels, forKey: .cels)
        try c.encode(hold, forKey: .hold)
    }
}

/// The on-disk document.
///
/// JSON, because at these sizes the whole animation is tens of KB of integers
/// and being able to read the file with `jq` is worth more than the bytes.
/// Written compactly, not pretty-printed: prettifying puts every palette index
/// on its own line, which turned three 48x48 frames into 120KB. The undo stack
/// is not saved; it belongs to a session, not to a drawing.
struct Project: Codable {
    var version = 2
    var layers: [LayerInfo]
    var palette: [String]
    var paletteName: String
    var selectedIndex: Int
    var frames: [Frame]
    var fps: Double
    /// Where the drawing came from, so `Options` and `Revert` still mean
    /// something after a reload. Nil for a project started from a blank canvas.
    var source: Source?

    struct Source: Codable {
        var path: String
        var gridSize: Int
        /// Pre-2026-09-19 files: whether the automatic content crop was on.
        /// Read and ignored; `crop` replaced it.
        var trim: Bool?
        /// [left, top, side] in source pixels: the square that was reduced.
        var crop: [Int]?
        /// Pre-2026-09-20 files: the import panel's ink dial. Read and ignored;
        /// the Fine/Medium/Bold options are that dial now.
        var inkBias: Double?
        /// Which reducer made the pick. Only ever "quantise" now; optional so
        /// files that recorded a second, since-removed method still open.
        var method: String?
        /// The option that was picked, kept whole. `Revert` restores this
        /// without touching the source file, which matters because the source
        /// may have moved, and because re-running the quantiser returns a
        /// different-looking sprite when the option came from the threshold path.
        var pickedLabel: String
        var pickedGrid: [[Int]]
        var pickedPalette: [String]
    }

    enum CodingKeys: String, CodingKey {
        case version, layers, palette, paletteName, selectedIndex, frames, fps, source
    }

    init(layers: [LayerInfo], palette: [String], paletteName: String, selectedIndex: Int,
         frames: [Frame], fps: Double, source: Source?) {
        self.layers = layers; self.palette = palette; self.paletteName = paletteName
        self.selectedIndex = selectedIndex; self.frames = frames; self.fps = fps
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        palette = try c.decode([String].self, forKey: .palette)
        paletteName = try c.decode(String.self, forKey: .paletteName)
        selectedIndex = try c.decode(Int.self, forKey: .selectedIndex)
        frames = try c.decode([Frame].self, forKey: .frames)
        fps = try c.decode(Double.self, forKey: .fps)
        source = try? c.decode(Source.self, forKey: .source)
        // A v1 file has no layer list; its frames decoded as one cel each.
        layers = (try? c.decode([LayerInfo].self, forKey: .layers))
            ?? [LayerInfo(name: "Layer 1")]
    }
}

enum ProjectFile {
    /// `.nibart`, not `.nib`. `.nib` belongs to Interface Builder, and handing
    /// Finder a file that looks like an Xcode resource is a trap for later.
    static let ext = "nibart"

    static var type: UTType { UTType(filenameExtension: ext) ?? .json }

    static func read(_ url: URL) throws -> Project {
        try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
    }

    static func write(_ project: Project, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(project).write(to: url, options: .atomic)
    }
}
