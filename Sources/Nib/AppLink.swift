import AppKit
import Foundation

/// The socket another process edits the open project through.
///
/// The app is a client of `nibd`; this is the one place it is a server. A
/// Claude session running `nib-mcp` asks `hello` for the document on screen,
/// works out an edit from it, and sends the finished document back as `apply`,
/// which lands in the window as a single labelled undo step.
///
/// Deliberately small: no rendering, no file access, no operations. Everything
/// an agent can do it already does in Python, and duplicating any of it here
/// would give two implementations to keep in step. See `docs/AGENT_TOOLS.md`.
///
/// `~/.nib/app.sock`, 0600, so it reaches as far as anything else running as
/// you: the same footing as `nibd.sock` next to it.
///
/// `@unchecked Sendable` is a claim, so here is the argument for it: `store` is
/// set once before the socket exists, and every store touch hops to the main
/// actor first.
final class AppLink: @unchecked Sendable {
    static let shared = AppLink()

    private let queue = DispatchQueue(label: "nib.applink")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private weak var store: CanvasStore?

    @MainActor
    func start(store: CanvasStore) {
        self.store = store
        queue.async { self.listen() }
    }

    func stop() {
        source?.cancel()
        source = nil
        // Only tidy up a socket this instance actually bound. A second Nib that
        // stood aside because the first owns the link must not delete it on the
        // way out, or quitting the spare kills the link for the one that stayed.
        guard listener >= 0 else { return }
        close(listener)
        listener = -1
        try? FileManager.default.removeItem(at: Paths.appSocket)
    }

    // MARK: - Socket

    private func listen() {
        let path = Paths.appSocket.path
        try? FileManager.default.createDirectory(at: Paths.state, withIntermediateDirectories: true)
        // A live Nib owns the link; a dead one leaves its socket file behind and
        // bind() on an existing path fails with EADDRINUSE. Tell them apart by
        // connecting, never by the file existing: the same reasoning as
        // NibClient's, from the other side of the socket. Getting this wrong
        // meant a second Nib took the link from the first without a word, and
        // the session driving the first one simply stopped being answered.
        if answers(path) { return }
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self), src, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else { close(fd); return }
        chmod(path, 0o600)
        listener = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    /// Is another Nib already listening there? Connecting is the only way to
    /// know: the file outlives the process that made it.
    private func answers(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self), src, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        } == 0
    }

    private func accept() {
        let conn = Darwin.accept(listener, nil, nil)
        guard conn >= 0 else { return }
        // Every connection on its own queue: a request waits on the main actor,
        // and doing that on the accept queue would stop the app answering a
        // second caller until the first was done.
        DispatchQueue(label: "nib.applink.conn").async {
            defer { close(conn) }
            while let line = Self.readLine(conn) {
                let reply = self.handle(line)
                guard Self.write(reply, to: conn) else { return }
            }
        }
    }

    // MARK: - Protocol

    private func handle(_ line: Data) -> [String: Any] {
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let command = request["cmd"] as? String else {
            return ["ok": false, "error": "expected a JSON object with a cmd"]
        }
        switch command {
        case "hello":  return onMain { self.hello($0) }
        case "apply":  return onMain { self.apply(request, $0) }
        case "save":   return onMain { self.saveDocument($0) }
        default:       return ["ok": false, "error": "unknown command \(command)"]
        }
    }

    /// The document on screen, and the version to send back with an edit.
    @MainActor
    private func hello(_ store: CanvasStore) -> [String: Any] {
        var reply: [String: Any] = [
            "ok": true,
            "version": store.documentVersion,
            "size": store.size,
            "frames": store.frames.count,
            "layers": store.layers.count,
            "dirty": store.isDirty,
        ]
        reply["path"] = store.projectURL?.path
        if let data = try? JSONEncoder().encode(store.snapshotProject()),
           let doc = try? JSONSerialization.jsonObject(with: data) {
            reply["doc"] = doc
        }
        return reply
    }

    @MainActor
    private func apply(_ request: [String: Any], _ store: CanvasStore) -> [String: Any] {
        guard let doc = request["doc"] else {
            return ["ok": false, "error": "apply needs a doc"]
        }
        let label = request["label"] as? String ?? "edit"
        do {
            let data = try JSONSerialization.data(withJSONObject: doc)
            let project = try JSONDecoder().decode(Project.self, from: data)
            try store.applyExternal(project, label: label, basedOn: request["version"] as? Int)
            // Fronting the window would yank focus mid-sentence from whatever
            // sent the edit. A flash of the Dock icon says it landed.
            NSApp.requestUserAttention(.informationalRequest)
            return ["ok": true, "version": store.documentVersion]
        } catch let e as NibError {
            if case .stale(_, let actual) = e {
                return ["ok": false, "stale": true, "version": actual,
                        "error": e.errorDescription ?? "stale"]
            }
            return ["ok": false, "error": e.errorDescription ?? "failed"]
        } catch {
            return ["ok": false, "error": "not a Nib document: \(error.localizedDescription)"]
        }
    }

    /// The window saves its own document, rather than the sender writing the
    /// file underneath it. Otherwise the file would be current while the window
    /// still believed it had unsaved work, and the next Cmd+S would write the
    /// same thing again for no reason.
    @MainActor
    private func saveDocument(_ store: CanvasStore) -> [String: Any] {
        guard let url = store.projectURL else {
            return ["ok": false, "error": "this project has never been saved, so there is "
                                        + "nowhere to save it to. The person needs Save As first."]
        }
        store.save()
        return ["ok": !store.isDirty, "path": url.path]
    }

    /// Run a block against the store on the main actor and wait for it. Safe
    /// from here because this only ever runs on a connection queue, so the main
    /// thread is never the one waiting.
    private func onMain(_ body: @escaping @MainActor (CanvasStore) -> [String: Any]) -> [String: Any] {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                guard let store = self.store else {
                    return ["ok": false, "error": "no project is open"]
                }
                return body(store)
            }
        }
    }

    // MARK: - JSON lines

    private static func readLine(_ fd: Int32) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return line.isEmpty ? nil : line }
            if byte == 0x0A { return line }
            line.append(byte)
            if line.count > 32 * 1024 * 1024 { return nil }
        }
    }

    @discardableResult
    private static func write(_ object: [String: Any], to fd: Int32) -> Bool {
        guard var payload = try? JSONSerialization.data(withJSONObject: object) else { return false }
        payload.append(0x0A)
        return payload.withUnsafeBytes { buf -> Bool in
            var sent = 0
            while sent < buf.count {
                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}
