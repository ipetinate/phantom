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

    /// Whether this process is hosting a test bundle rather than a reader.
    ///
    /// The environment variable is XCTest's own, set by the runner in the host
    /// process before the bundle is injected.
    ///
    /// `nonisolated` because it reads nothing but the environment, and the
    /// question is asked from outside the main actor: `EditorUndoArchive`
    /// resolves its folder on whatever thread a save happens on and has to
    /// know whether it is running under a test host before it writes.
    nonisolated static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
    }

    /// Whether something is accepting connections on this socket right now.
    ///
    /// A plain `connect`, because that is the only question with a true answer:
    /// the file existing says nothing, and a pid file would be a second source
    /// of truth to keep honest. Connected means somebody is there, so this
    /// process must not take the path from them.
    static func isAccepting(at url: URL) -> Bool {
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { raw in
            url.path.withCString { source in
                strncpy(
                    UnsafeMutableRawPointer(raw).assumingMemoryBound(to: CChar.self),
                    source,
                    MCPSocketPath.maximumLength)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, size) }
        } == 0
    }

    func start() {
        guard listener < 0 else { return }

        /// A test run must never own this. `xcodebuild test` hosts the test
        /// bundle *inside the app*, so it is a second instance with the same
        /// bundle id and therefore the same socket path — and it exits when the
        /// suite ends. Left to start, it takes the socket from the copy the
        /// reader is using and takes MCP down with it when it goes, which is
        /// exactly what happened here: a green test run and an agent that could
        /// no longer reach the app.
        guard !Self.isTesting else {
            WindowBreadcrumbs.note("mcp: not listening, this process is a test host")
            return
        }

        let url = MCPSocketPath.current
        guard MCPSocketPath.fits(url) else {
            WindowBreadcrumbs.note("mcp: socket path too long for sun_path: \(url.path)")
            return
        }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        /// A socket file left by a crash keeps `bind` from succeeding, and
        /// removing it is how the next launch gets to listen at all.
        ///
        /// But the old comment here claimed nothing could ever be connected to
        /// it, "because the process that accepted on it is gone" — and that is
        /// only true of a crash. A *second instance of this same app* has the
        /// same bundle id and so the same path, and deleting the file out from
        /// under a live listener leaves the first instance accepting on an
        /// inode no path reaches any more: it looks healthy from inside and
        /// refuses every connection from outside. So the file is probed first
        /// and only removed when nothing answers.
        if Self.isAccepting(at: url) {
            WindowBreadcrumbs.note("mcp: another instance is already listening on \(url.path)")
            return
        }
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
        } call: { [weak self] request, context, answer in
            guard let self else {
                return answer(.failure(.internalError("Phantom is not listening.")))
            }
            self.service.call(request, context: context, then: answer)
        } onClose: { [weak self] connection in
            MCPPermissionStore.shared.forget(client: ObjectIdentifier(connection))
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

    /// Tools are answered on their own path because one of them may have to
    /// put a question in front of the reader, and that takes as long as it
    /// takes.
    private let call: (
        MCPMessage.Request,
        (String, [String: JSONValue]) -> MCPToolContext,
        @escaping (Result<JSONValue, MCPMessage.Failure>) -> Void
    ) -> Void

    private let onClose: (MCPConnection) -> Void

    private let queue = DispatchQueue(label: "com.ipetinate.phantom.mcp.connection")
    private var source: DispatchSourceRead?
    private var pending = Data()

    /// Nil until the hello arrives. Nothing is answered before it: a client
    /// that starts asking questions without identifying itself is refused,
    /// which is also what a client of the wrong version looks like.
    private var surface: UUID?

    /// What the client called itself in the hello. Shown to the reader in the
    /// permission sheet and trusted for nothing else.
    private var clientName: String?

    private var isReady = false

    init(
        handle: Int32,
        answer: @escaping (MCPMessage.Request) -> Result<JSONValue, MCPMessage.Failure>,
        call: @escaping (
            MCPMessage.Request,
            (String, [String: JSONValue]) -> MCPToolContext,
            @escaping (Result<JSONValue, MCPMessage.Failure>) -> Void
        ) -> Void,
        onClose: @escaping (MCPConnection) -> Void
    ) {
        self.handle = handle
        self.answer = answer
        self.call = call
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

            /// The one method that cannot be answered from a value, because
            /// it may have to wait for the reader.
            if request.method == "tools/call" {
                let client = ObjectIdentifier(self)
                let surface = self.surface
                let name = self.clientName
                call(request, { _, arguments in
                    MCPToolContext(
                        callerSurface: surface,
                        clientName: name,
                        client: client,
                        arguments: arguments)
                }, { [weak self] result in
                    switch result {
                    case .success(let value):
                        self?.write(MCPMessage.response(id: request.id, result: value))
                    case .failure(let failure):
                        self?.write(MCPMessage.response(id: request.id, failure: failure))
                    }
                })
                return
            }

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
            self.clientName = hello.client
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
