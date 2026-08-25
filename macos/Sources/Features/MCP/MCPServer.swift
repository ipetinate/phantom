import Darwin
import Foundation

/// The listener the terminals' agents connect to.
///
/// A Unix socket, not a port. This is a control surface — it will run
/// commands, open terminals and hand out scope — and a socket's permissions
/// are enforced by the kernel, where a port's are enforced by a secret in a
/// config file that agents print in their own logs. It also sidesteps
/// discovery: a debug build and a release build each own a path named after
/// their bundle, and neither can answer for the other.
///
/// Everything this class does is plumbing, on purpose. The handshake, the
/// framing and the answers are values elsewhere — `MCPHandshake`,
/// `MCPMessage`, `MCPService` — because a socket is the one part of this that
/// no test can hold.
@MainActor
final class MCPServer {
    static let shared = MCPServer()

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: MCPConnection] = [:]

    private(set) var service = MCPService()

    /// Where it is listening, for the settings pane and for the breadcrumbs.
    private(set) var socketURL: URL?

    func start() {
        guard listener < 0 else { return }

        let url = MCPSocketPath.current
        guard MCPSocketPath.fits(url) else {
            WindowBreadcrumbs.note("mcp: socket path too long for sun_path: \(url.path)")
            return
        }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        /// A socket file left by a crash keeps `bind` from succeeding, and it
        /// is never anything to preserve: nothing can be connected to it,
        /// because the process that accepted on it is gone.
        try? FileManager.default.removeItem(at: url)

        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else {
            WindowBreadcrumbs.note("mcp: socket() failed, errno \(errno)")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = url.path
        _ = withUnsafeMutablePointer(to: &address.sun_path) { raw in
            path.withCString { source in
                strncpy(
                    UnsafeMutableRawPointer(raw).assumingMemoryBound(to: CChar.self),
                    source,
                    MCPSocketPath.maximumLength)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(handle, $0, size) }
        }

        guard bound == 0, listen(handle, 8) == 0 else {
            WindowBreadcrumbs.note("mcp: bind/listen failed, errno \(errno)")
            close(handle)
            return
        }

        /// Only this user, enforced by the filesystem. The directory is
        /// `~/.cache/phantom`, which is already the reader's own.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path)

        listener = handle
        socketURL = url
        WindowBreadcrumbs.note("mcp: listening on \(path)")

        let source = DispatchSource.makeReadSource(fileDescriptor: handle, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil

        for connection in connections.values { connection.close() }
        connections.removeAll()

        if listener >= 0 {
            close(listener)
            listener = -1
        }

        if let socketURL { try? FileManager.default.removeItem(at: socketURL) }
        socketURL = nil
    }

    private func accept() {
        let handle = Darwin.accept(listener, nil, nil)
        guard handle >= 0 else { return }

        let connection = MCPConnection(handle: handle) { [weak self] request in
            self?.service.answer(request) ?? .failure(.internalError("Phantom is not listening."))
        } onClose: { [weak self] connection in
            self?.connections.removeValue(forKey: ObjectIdentifier(connection))
        }

        connections[ObjectIdentifier(connection)] = connection
        connection.resume()
    }
}

/// One client, from the handshake to the last line.
///
/// Reads on a queue of its own and answers on the main actor, because every
/// question a tool can ask — which tabs exist, what is running in one — is
/// main-actor state.
@MainActor
final class MCPConnection {
    private let handle: Int32
    private let answer: (MCPMessage.Request) -> Result<JSONValue, MCPMessage.Failure>
    private let onClose: (MCPConnection) -> Void

    private let queue = DispatchQueue(label: "com.ipetinate.phantom.mcp.connection")
    private var source: DispatchSourceRead?
    private var pending = Data()

    /// Nil until the hello arrives. Nothing is answered before it: a client
    /// that starts asking questions without identifying itself is refused,
    /// which is also what a client of the wrong version looks like.
    private var surface: UUID?
    private var isReady = false

    init(
        handle: Int32,
        answer: @escaping (MCPMessage.Request) -> Result<JSONValue, MCPMessage.Failure>,
        onClose: @escaping (MCPConnection) -> Void
    ) {
        self.handle = handle
        self.answer = answer
        self.onClose = onClose
    }

    func resume() {
        let source = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let chunk = Self.read(self.handle)
            Task { @MainActor in self.received(chunk) }
        }
        source.setCancelHandler { [handle] in Darwin.close(handle) }
        source.resume()
        self.source = source
    }

    func close() {
        source?.cancel()
        source = nil
    }

    private nonisolated static func read(_ handle: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(handle, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return Data(buffer[0..<count])
    }

    private func received(_ chunk: Data?) {
        guard let chunk else {
            close()
            onClose(self)
            return
        }

        pending.append(chunk)

        /// One message per line. MCP over stdio is framed this way, so the
        /// helper relaying between them has nothing to translate.
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<end]
            pending = pending[pending.index(after: end)...]
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard isReady else { return greet(with: line) }

        switch MCPMessage.parse(line: line) {
        case .success(let request):
            /// A notification is not answered at all. Answering one leaves the
            /// client waiting on a response to something it never asked for.
            guard !request.isNotification else { return }

            switch answer(request) {
            case .success(let result):
                write(MCPMessage.response(id: request.id, result: result))
            case .failure(let failure):
                write(MCPMessage.response(id: request.id, failure: failure))
            }

        case .failure(let refusal):
            write(MCPMessage.response(id: refusal.id, failure: refusal.failure))
        }
    }

    private func greet(with line: Data) {
        guard let hello = try? JSONDecoder().decode(MCPHandshake.Hello.self, from: line) else {
            write(hello: .refused("The first line must be a Phantom MCP hello."))
            close()
            onClose(self)
            return
        }

        switch MCPHandshake.answer(to: hello, peerPID: Self.peerPID(handle)) {
        case .accepted(let surface):
            self.surface = surface
            isReady = true
            WindowBreadcrumbs.note(
                "mcp: client \(hello.client ?? "unknown") on "
                + "\(surface?.uuidString ?? "no tab") accepted")
            write(hello: .accepted(surface: surface))

        case .refused(let reason):
            WindowBreadcrumbs.note("mcp: refused a client: \(reason)")
            write(hello: .refused(reason))
            close()
            onClose(self)
        }
    }

    private func write(hello answer: MCPHandshake.Answer) {
        switch answer {
        case .accepted(let surface):
            write(try? JSONValue.object([
                "ok": .bool(true),
                "version": .number(Double(MCPHandshake.version)),
                "tab": surface.map { .string($0.uuidString) } ?? .null,
            ]).data())
        case .refused(let reason):
            write(try? JSONValue.object([
                "ok": .bool(false),
                "version": .number(Double(MCPHandshake.version)),
                "error": .string(reason),
            ]).data())
        }
    }

    private func write(_ payload: Data?) {
        guard var payload else { return }
        payload.append(UInt8(ascii: "\n"))

        let handle = self.handle
        queue.async {
            payload.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let count = Darwin.write(handle, raw.baseAddress! + sent, raw.count - sent)
                    guard count > 0 else { return }
                    sent += count
                }
            }
        }
    }

    /// What the kernel says about the other end, which is the only claim in
    /// the handshake that cannot be typed by the caller.
    private nonisolated static func peerPID(_ handle: Int32) -> Int32? {
        var credentials = xucred()
        var size = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(handle, 0, LOCAL_PEERCRED, &credentials, &size) == 0 else { return nil }

        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(handle, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0 else { return nil }
        return pid
    }
}
