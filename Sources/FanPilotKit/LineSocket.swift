import Darwin
import Foundation

// Unix-domain socket transport for the NDJSON protocol, shared by the helper (server side) and the
// app / CLI (client side).
//
// Design notes:
//  - Plain POSIX sockets with a poll() based timeout; no Network.framework (it cannot do AF_UNIX
//    listeners the way we need and hides peer credentials).
//  - SO_NOSIGPIPE on every fd: a client that disappears must never kill the root daemon with SIGPIPE.
//  - Writes carry a send timeout so a client that stops reading cannot block the helper forever.

public enum LineSocketError: Error, Equatable, Sendable, CustomStringConvertible {
    case pathTooLong(String)
    case notASocket(String)
    case addressInUse(String)
    case socketFailed(errno: Int32)
    case connectFailed(path: String, errno: Int32)
    case bindFailed(path: String, errno: Int32)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case lineTooLong(limit: Int)
    case invalidLine
    case timeout
    case closed

    public var description: String {
        func e(_ n: Int32) -> String { String(cString: strerror(n)) }
        switch self {
        case .pathTooLong(let p): return "socket path too long: \(p)"
        case .notASocket(let p): return "refusing to replace \(p): it exists and is not a socket"
        case .addressInUse(let p): return "another process is already serving \(p)"
        case .socketFailed(let n): return "socket() failed: \(e(n))"
        case .connectFailed(let p, let n): return "cannot connect to \(p): \(e(n))"
        case .bindFailed(let p, let n): return "cannot bind \(p): \(e(n))"
        case .listenFailed(let n): return "listen() failed: \(e(n))"
        case .acceptFailed(let n): return "accept() failed: \(e(n))"
        case .readFailed(let n): return "read failed: \(e(n))"
        case .writeFailed(let n): return "write failed: \(e(n))"
        case .lineTooLong(let limit): return "line exceeds \(limit) bytes"
        case .invalidLine: return "line contains a newline"
        case .timeout: return "timed out"
        case .closed: return "connection closed"
        }
    }
}

/// Credentials of the process on the other end of a Unix socket (kernel supplied, unforgeable).
public struct PeerCredentials: Equatable, Sendable {
    public var uid: uid_t
    public var gid: gid_t
    public var pid: pid_t
}

// sys/un.h and sys/ucred.h constants that Swift does not always import.
private let solLocal: Int32 = 0
private let localPeerCred: Int32 = 0x001
private let localPeerPID: Int32 = 0x002
private let localPeerToken: Int32 = 0x006

/// One connected socket speaking newline-delimited messages.
///
/// Thread rules: at most one thread reads (`readLine`, or the loop started by `startReading`);
/// any number of threads may write (writes are serialized). To stop a blocked reader from another
/// thread call `shutdown()`; call `close()` once the reader is done (or let `deinit` do it).
public final class LineSocketConnection: @unchecked Sendable {
    private var fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private let maxLineBytes: Int
    private var framer: LineFramer
    private var pending: [Data] = []
    private var sawEOF = false

    /// Takes ownership of `fd` (it will be closed by `close()` / `deinit`).
    public init(fd: Int32, maxLineBytes: Int = Constants.maxLineBytes,
                sendTimeout: TimeInterval = Constants.socketSendTimeoutSeconds) {
        self.fd = fd
        self.maxLineBytes = maxLineBytes
        self.framer = LineFramer(maxLineBytes: maxLineBytes)

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(sendTimeout), tv_usec: Int32((sendTimeout - floor(sendTimeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit {
        close()
    }

    // MARK: Client

    /// Connects to a Unix socket path.
    public static func connect(path: String, maxLineBytes: Int = Constants.maxLineBytes) throws -> LineSocketConnection {
        var address = try makeAddress(path: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LineSocketError.socketFailed(errno: errno) }

        let result = withUnsafePointer(to: &address) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw LineSocketError.connectFailed(path: path, errno: code)
        }
        return LineSocketConnection(fd: fd, maxLineBytes: maxLineBytes)
    }

    /// A connected pair of in-process sockets, for tests.
    public static func makePair() throws -> (LineSocketConnection, LineSocketConnection) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw LineSocketError.socketFailed(errno: errno)
        }
        return (LineSocketConnection(fd: fds[0]), LineSocketConnection(fd: fds[1]))
    }

    // MARK: Reading

    /// Blocks until a complete line is available and returns it (without the newline).
    /// Returns nil at end of stream. Throws `.timeout` if `timeout` elapses first, `.lineTooLong`
    /// if the peer sends an over-long line (the connection should then be closed).
    public func readLine(timeout: TimeInterval? = nil) throws -> Data? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            if !pending.isEmpty { return pending.removeFirst() }
            if sawEOF { return nil }

            let currentFD = descriptor()
            guard currentFD >= 0 else { return nil }

            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { throw LineSocketError.timeout }
                var pfd = pollfd(fd: currentFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
                if ready == 0 { throw LineSocketError.timeout }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw LineSocketError.readFailed(errno: errno)
                }
            }

            let n = buffer.withUnsafeMutableBytes { Darwin.read(currentFD, $0.baseAddress, $0.count) }
            if n == 0 {
                sawEOF = true
                return pending.isEmpty ? nil : pending.removeFirst()
            }
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                // shutdown() from another thread surfaces as EOF or ECONNRESET/EBADF; all mean "done".
                if code == ECONNRESET || code == EBADF || code == ENOTCONN {
                    sawEOF = true
                    return nil
                }
                throw LineSocketError.readFailed(errno: code)
            }
            do {
                pending.append(contentsOf: try framer.append(Data(buffer[0..<n])))
            } catch {
                throw LineSocketError.lineTooLong(limit: maxLineBytes)
            }
        }
    }

    /// Runs a read loop on `queue` (a private serial queue by default; do not pass a queue you need
    /// for other work, the loop blocks it). `onLine` is called for every line in order; `onClose`
    /// exactly once when the stream ends (error is nil for a clean EOF). The connection is closed
    /// after `onClose`.
    public func startReading(on queue: DispatchQueue? = nil,
                             onLine: @escaping @Sendable (Data) -> Void,
                             onClose: @escaping @Sendable (Error?) -> Void) {
        let readQueue = queue ?? DispatchQueue(label: "com.fanpilot.linesocket.read")
        readQueue.async { [self] in
            var failure: Error?
            do {
                while let line = try readLine() { onLine(line) }
            } catch {
                failure = error
            }
            onClose(failure)
            close()
        }
    }

    // MARK: Writing

    /// Sends `data` followed by a newline. `data` must not contain a newline.
    public func writeLine(_ data: Data) throws {
        guard data.count <= maxLineBytes else { throw LineSocketError.lineTooLong(limit: maxLineBytes) }
        guard !data.contains(0x0A) else { throw LineSocketError.invalidLine }
        var message = data
        message.append(0x0A)
        try writeAll(message)
    }

    private func writeAll(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let currentFD = descriptor()
        guard currentFD >= 0 else { throw LineSocketError.closed }

        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(currentFD, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    if code == EAGAIN || code == EWOULDBLOCK { throw LineSocketError.timeout }
                    if code == EPIPE || code == ECONNRESET || code == EBADF { throw LineSocketError.closed }
                    throw LineSocketError.writeFailed(errno: code)
                }
                offset += n
            }
        }
    }

    // MARK: Typed helpers (wire protocol)

    /// Encodes `value` as JSON and sends it as one line.
    public func send<T: Encodable>(_ value: T) throws {
        try writeLine(try WireCodec.encode(value, maxLineBytes: maxLineBytes))
    }

    /// Reads and decodes one message; nil at end of stream.
    public func receive<T: Decodable>(_ type: T.Type, timeout: TimeInterval? = nil) throws -> T? {
        guard let line = try readLine(timeout: timeout) else { return nil }
        return try WireCodec.decode(type, from: line, maxLineBytes: maxLineBytes)
    }

    // MARK: Lifecycle

    public var isClosed: Bool { descriptor() < 0 }

    /// Shuts down both directions. Safe from any thread; unblocks a pending `readLine`.
    public func shutdown() {
        let currentFD = descriptor()
        if currentFD >= 0 { Darwin.shutdown(currentFD, SHUT_RDWR) }
    }

    /// Closes the descriptor. Call from the thread that reads, or after the reader has finished.
    public func close() {
        stateLock.lock()
        let old = fd
        fd = -1
        stateLock.unlock()
        if old >= 0 { Darwin.close(old) }
    }

    private func descriptor() -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fd
    }

    // MARK: Peer identity (server side)

    /// uid/gid/pid of the peer, from `LOCAL_PEERCRED` and `LOCAL_PEERPID`.
    public func peerCredentials() -> PeerCredentials? {
        let currentFD = descriptor()
        guard currentFD >= 0 else { return nil }

        var cred = xucred()
        var credLength = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(currentFD, solLocal, localPeerCred, &cred, &credLength) == 0,
              cred.cr_version == UInt32(XUCRED_VERSION) else { return nil }

        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(currentFD, solLocal, localPeerPID, &pid, &pidLength) == 0 else { return nil }

        let gid = cred.cr_ngroups > 0 ? cred.cr_groups.0 : gid_t.max
        return PeerCredentials(uid: cred.cr_uid, gid: gid, pid: pid)
    }

    /// The peer's audit token as 32 raw bytes (`audit_token_t`), for `SecCodeCopyGuestWithAttributes`
    /// in pinned auth mode (docs/SPEC.md 4.3). Nil if the kernel does not provide it.
    public func peerAuditTokenData() -> Data? {
        let currentFD = descriptor()
        guard currentFD >= 0 else { return nil }
        var token = [UInt8](repeating: 0, count: 32)
        var length = socklen_t(token.count)
        guard getsockopt(currentFD, solLocal, localPeerToken, &token, &length) == 0, length == 32 else { return nil }
        return Data(token)
    }
}

// MARK: - Typed convenience for requests / replies

extension LineSocketConnection {
    public func sendRequest(_ request: WireRequest) throws {
        try writeLine(try WireCodec.encode(request))
    }

    public func sendReply(_ reply: WireReply) throws {
        try writeLine(try WireCodec.encode(reply))
    }

    /// Reads the next request; nil at end of stream. Throws `WireError` for undecodable lines.
    public func readRequest(timeout: TimeInterval? = nil) throws -> WireRequest? {
        guard let line = try readLine(timeout: timeout) else { return nil }
        return try WireCodec.decodeRequest(line)
    }

    public func readReply(timeout: TimeInterval? = nil) throws -> WireReply? {
        guard let line = try readLine(timeout: timeout) else { return nil }
        return try WireCodec.decodeReply(line)
    }
}

// MARK: - Address helper

private func makeAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    let bytes = Array(path.utf8)
    guard !bytes.isEmpty, bytes.count < capacity else { throw LineSocketError.pathTooLong(path) }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

// MARK: - Server

/// A listening Unix-domain socket.
///
/// `start()` refuses to replace anything that is not a socket (the helper runs as root and must
/// not delete arbitrary files) and refuses if a live server already answers on the path.
public final class LineSocketServer: @unchecked Sendable {
    public let path: String
    public let fileMode: mode_t
    private let maxLineBytes: Int
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// True once `acceptSource` is responsible for closing the listening descriptor.
    private var ownsDescriptorThroughSource = false
    private let lock = NSLock()

    /// - Parameter fileMode: permission bits of the socket file. 0o666 lets any local user connect;
    ///   authorization is then done per connection via peer credentials (docs/SPEC.md 4.3).
    public init(path: String, fileMode: mode_t = 0o666, maxLineBytes: Int = Constants.maxLineBytes) {
        self.path = path
        self.fileMode = fileMode
        self.maxLineBytes = maxLineBytes
    }

    deinit {
        stop()
    }

    /// Binds and listens.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listenFD < 0 else { return }

        var address = try makeAddress(path: path)
        try removeStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LineSocketError.socketFailed(errno: errno) }

        let bound = withUnsafePointer(to: &address) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw LineSocketError.bindFailed(path: path, errno: code)
        }
        // bind() applied the process umask; set the intended mode explicitly.
        chmod(path, fileMode)

        guard listen(fd, SOMAXCONN) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw LineSocketError.listenFailed(errno: code)
        }
        // Non-blocking so accept never hangs after a poll() race.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
    }

    /// Accepts connections on `queue` using a GCD read source. `handler` runs once per connection.
    public func startAccepting(on queue: DispatchQueue, handler: @escaping @Sendable (LineSocketConnection) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard listenFD >= 0, acceptSource == nil else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while let connection = try? self.acceptNow() {
                handler(connection)
            }
        }
        // GCD requires that a descriptor watched by a source is closed from its cancel handler.
        let watchedFD = listenFD
        source.setCancelHandler { Darwin.close(watchedFD) }
        acceptSource = source
        ownsDescriptorThroughSource = true
        source.resume()
    }

    /// Accepts one connection, waiting up to `timeout` seconds (nil waits forever). Returns nil on
    /// timeout. For tests and simple servers; production code uses `startAccepting`.
    public func accept(timeout: TimeInterval? = nil) throws -> LineSocketConnection? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            lock.lock()
            let fd = listenFD
            lock.unlock()
            guard fd >= 0 else { throw LineSocketError.closed }

            if let connection = try acceptNow() { return connection }

            var waitMs: Int32 = -1
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return nil }
                waitMs = Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up))
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, waitMs)
            if ready < 0, errno != EINTR { throw LineSocketError.acceptFailed(errno: errno) }
        }
    }

    /// Stops listening and removes the socket file.
    public func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        let source = acceptSource
        acceptSource = nil
        let sourceCloses = ownsDescriptorThroughSource
        ownsDescriptorThroughSource = false
        lock.unlock()

        source?.cancel()
        if fd >= 0 {
            if !sourceCloses { Darwin.close(fd) }
            unlink(path)
        }
    }

    private func acceptNow() throws -> LineSocketConnection? {
        lock.lock()
        let fd = listenFD
        lock.unlock()
        guard fd >= 0 else { throw LineSocketError.closed }

        let client = Darwin.accept(fd, nil, nil)
        if client < 0 {
            let code = errno
            if code == EAGAIN || code == EWOULDBLOCK || code == EINTR || code == ECONNABORTED { return nil }
            throw LineSocketError.acceptFailed(errno: code)
        }
        // Accepted sockets inherit O_NONBLOCK from some kernels; readers here are blocking.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        return LineSocketConnection(fd: client, maxLineBytes: maxLineBytes)
    }

    /// Removes a leftover socket file from a previous run, but only if nothing is serving on it.
    private func removeStaleSocket() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }          // nothing there
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw LineSocketError.notASocket(path) }

        if let probe = try? LineSocketConnection.connect(path: path) {
            probe.close()
            throw LineSocketError.addressInUse(path)
        }
        unlink(path)
    }
}
