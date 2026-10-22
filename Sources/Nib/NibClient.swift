import Foundation

/// Every filesystem path Nib knows lives here. One home, so making them
/// configurable later is one file rather than a search.
enum Paths {
    static let state = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".nib")
    static var socket: URL { state.appendingPathComponent("nibd.sock") }
    /// The other direction: where the *app* listens, for the live link.
    static var appSocket: URL { state.appendingPathComponent("app.sock") }
    static var output: URL { state.appendingPathComponent("output") }

    /// The daemon lives next to the app source, not in the state directory:
    /// code here, data there.
    ///
    /// Inside a built `.app` it is copied into Resources, so a bundle can be
    /// moved to another machine and still work. `#filePath` is the development
    /// path and only resolves on the machine that compiled it, so the bundle is
    /// checked first and that is the fallback.
    static var daemon: URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("nibd")
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("nibd.py").path) {
                return bundled
            }
        }
        return sourceDaemon
    }

    private static let sourceDaemon = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/Nib
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("nibd")

    /// A Python that can import Pillow, or nil.
    ///
    /// This used to be `/usr/bin/env python3`. From a terminal that is whatever
    /// your shell says; from Finder or the Dock the PATH is launchd's, which
    /// finds Apple's 3.9 with no Pillow, and the daemon died on its first
    /// import. The app only ever worked because a daemon started from a
    /// terminal was already running. So: ask each likely Python whether it can
    /// import PIL, and take the first that can. `NIB_PYTHON` overrides.
    static let python: String? = {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Override, then whatever a terminal would run, then the usual homes.
        let onPath = (env["PATH"] ?? "").split(separator: ":").map { "\($0)/python3" }
        let candidates = [env["NIB_PYTHON"]].compactMap { $0 } + onPath + [
            "/opt/homebrew/Caskroom/miniforge/base/bin/python3",
            "\(home)/miniforge3/bin/python3",
            "\(home)/miniconda3/bin/python3",
            "\(home)/anaconda3/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        return candidates.first { hasPillow($0) }
    }()

    private static func hasPillow(_ python: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-c", "import PIL"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The daemon's stderr, so a crash on startup says why somewhere.
    static var log: URL { state.appendingPathComponent("nibd.log") }
}

enum NibError: LocalizedError {
    case daemonUnavailable(String)
    case badReply(String)
    case failed(String)
    /// The live link only: an edit built on a canvas that has since changed.
    case stale(expected: Int, actual: Int)
    case badDocument(String)

    var errorDescription: String? {
        switch self {
        case .daemonUnavailable(let s): return "nibd is not answering: \(s)"
        case .badReply(let s): return "nibd sent something unreadable: \(s)"
        case .failed(let s): return s
        case .stale(let e, let a):
            return "the canvas moved on: this edit was built on version \(e), the window is at \(a)"
        case .badDocument(let s): return "cannot apply \(s)"
        }
    }
}

/// JSON-lines client for `nibd` over a Unix socket, and the thing that starts the
/// daemon when it is not already running. Blocking calls are wrapped once, here,
/// so stores only ever `await`.
/// `@unchecked Sendable` is a claim, so here is the argument for it: every
/// mutable field is touched only from inside `queue`, which is serial.
final class NibClient: @unchecked Sendable {
    static let shared = NibClient()

    private let queue = DispatchQueue(label: "nib.client", qos: .userInitiated)
    private var lastLaunch: Date?

    func send(_ request: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try self.sendSync(request)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Streaming variant: `onEvent` is called for every line the daemon sends
    /// until one carries "done". Used by refine, which reports each model step
    /// as it happens rather than going quiet for a minute.
    func stream(
        _ request: [String: Any],
        onEvent: @escaping @Sendable ([String: Any]) -> Void
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try self.streamSync(request, onEvent: onEvent)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: - Blocking implementation

    private func sendSync(_ request: [String: Any]) throws -> [String: Any] {
        let fd = try openConnection()
        defer { close(fd) }

        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                if n <= 0 { throw NibError.daemonUnavailable("write failed") }
                sent += n
            }
        }

        // Replies are one line; a grid at 64x64 is comfortably under a megabyte.
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !data.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        guard let line = data.split(separator: 0x0A).first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        else {
            throw NibError.badReply(String(data: data.prefix(200), encoding: .utf8) ?? "<binary>")
        }
        if obj["ok"] as? Bool != true {
            throw NibError.failed(obj["error"] as? String ?? "nibd reported failure")
        }
        return obj
    }

    private func streamSync(
        _ request: [String: Any],
        onEvent: @escaping @Sendable ([String: Any]) -> Void
    ) throws -> [String: Any] {
        let fd = try openConnection()
        defer { close(fd) }
        try writeLine(request, to: fd)

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            // Drain whole lines out of the buffer before reading more, so a
            // single read carrying several events is not collapsed into one.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                else { continue }
                if obj["done"] as? Bool == true {
                    if obj["ok"] as? Bool != true {
                        throw NibError.failed(obj["error"] as? String ?? "refine failed")
                    }
                    return obj
                }
                onEvent(obj)
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { throw NibError.badReply("nibd closed the connection mid-stream") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private func writeLine(_ request: [String: Any], to fd: Int32) throws {
        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                if n <= 0 { throw NibError.daemonUnavailable("write failed") }
                sent += n
            }
        }
    }

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NibError.daemonUnavailable("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Paths.socket.path
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self), src, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        if ok != 0 {
            close(fd)
            throw NibError.daemonUnavailable("nothing is listening on \(Paths.socket.lastPathComponent)")
        }
        return fd
    }

    /// Connect, starting the daemon if nothing answers.
    ///
    /// Deliberately keyed off a failed connect rather than a missing socket
    /// file. `nibd` unlinks the socket when it starts and not when it dies, so
    /// after a crash the file is still sitting there: the app saw it, decided a
    /// daemon must be running, never started one, and every call failed until
    /// the file was deleted by hand.
    private func openConnection() throws -> Int32 {
        if let fd = try? connect() { return fd }
        try? FileManager.default.removeItem(at: Paths.socket)
        try startDaemon()
        return try connect()
    }

    private func startDaemon() throws {
        // Rate limited rather than once-only: the daemon can die at any point in
        // a long session, and refusing to ever start a second one turns that
        // into "restart the app".
        if let t = lastLaunch, Date().timeIntervalSince(t) < 3 {
            throw NibError.daemonUnavailable("nibd was just started and is not answering")
        }
        lastLaunch = Date()

        guard let python = Paths.python else {
            throw NibError.daemonUnavailable(
                "no Python with Pillow found. Install it (pip install pillow) or set NIB_PYTHON.")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["nibd.py"]
        p.currentDirectoryURL = Paths.daemon
        p.standardOutput = FileHandle.nullDevice
        try? FileManager.default.createDirectory(at: Paths.state, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Paths.log.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: Paths.log)) ?? FileHandle.nullDevice
        try p.run()

        // Wait for a connection to succeed, not for the file to exist: the
        // socket appears a moment before bind() finishes on a cold start, and a
        // cold start is dominated by importing Pillow, so its length varies.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let fd = try? connect() { close(fd); return }
            usleep(100_000)
        }
        throw NibError.daemonUnavailable("nibd did not start; see \(Paths.log.path)")
    }
}
