import Darwin
import Foundation

/// Request-scoped values that low-level callback APIs need in order to honor
/// the authenticated wire request's absolute deadline without broadening every
/// service protocol. Task-local values follow the asynchronous actor hop into
/// `HostController` and its capture service.
enum HostRequestTaskContext {
    @TaskLocal static var deadline: Date?
}

public actor WireConnectionSession {
    private let peer: SocketPeerCredentials
    private let authenticationToken: String
    private let connections: ConnectionRegistry
    private let replayGuard: HandshakeReplayGuard
    private let handler: HostMethodHandling
    private var connection: ConnectionRecord?
    private var seenRequestIDs: Set<String> = []

    public init(
        peer: SocketPeerCredentials,
        authenticationToken: String,
        connections: ConnectionRegistry,
        replayGuard: HandshakeReplayGuard,
        handler: HostMethodHandling
    ) {
        self.peer = peer
        self.authenticationToken = authenticationToken
        self.connections = connections
        self.replayGuard = replayGuard
        self.handler = handler
    }

    public func dispatch(_ request: WireRequest) async -> WireResponse {
        do {
            guard !request.id.isEmpty, request.id.count <= 256 else {
                throw WireError(code: "invalid_request_id", message: "Request id is invalid")
            }
            guard seenRequestIDs.insert(request.id).inserted else {
                throw WireError(code: "duplicate_request_id", message: "Request id was already used")
            }
            if seenRequestIDs.count > 4_096 { throw WireError(code: "request_limit", message: "Reconnect before sending more requests") }
            if request.method == "hello" { return try await hello(request) }
            let context = try await authorize(request)
            if request.method == "cancel" {
                // The socket loop owns Task instances and performs the cancel.
                return .success(id: request.id, result: .object(["accepted": .bool(true)]))
            }
            let result = try await HostRequestTaskContext.$deadline.withValue(context.deadline) {
                try await handler.handle(method: request.method, params: request.params, context: context)
            }
            if Task.isCancelled { throw WireError(code: "canceled", message: "Request was canceled", retryable: true) }
            guard Date() < context.deadline else { throw WireError(code: "deadline_exceeded", message: "Request deadline elapsed", retryable: true) }
            return .success(id: request.id, result: result)
        } catch {
            return .failure(id: request.id, error: WireErrorMapping.map(error))
        }
    }

    public func validateCancel(_ request: WireRequest) async throws -> String {
        guard seenRequestIDs.insert(request.id).inserted else {
            throw WireError(code: "duplicate_request_id", message: "Request id was already used")
        }
        _ = try await authorize(request)
        guard let requestID = request.params?.objectValue?["requestId"]?.stringValue,
              !requestID.isEmpty else {
            throw WireError(code: "invalid_request", message: "cancel requires requestId")
        }
        return requestID
    }

    public func close() async {
        guard let connection else { return }
        self.connection = nil
        await connections.close(connectionID: connection.id)
        await handler.disconnect(connectionID: connection.id)
    }

    private func hello(_ request: WireRequest) async throws -> WireResponse {
        guard connection == nil else { throw WireError(code: "already_authenticated", message: "hello may be sent only once") }
        guard ProtocolVersion.current.isCompatible(with: request.protocolVersion) else {
            throw ConnectionValidationError.incompatibleProtocol
        }
        guard let supplied = request.auth?.token, secureStringsEqual(supplied, authenticationToken),
              let client = request.client,
              let nonce = request.nonce else {
            throw ConnectionValidationError.unauthenticated
        }
        guard client.uid == peer.uid else { throw ConnectionValidationError.peerUIDMismatch }
        guard client.processID == peer.processID else { throw ConnectionValidationError.peerPIDMismatch }
        try await replayGuard.consume(nonce: nonce)
        let token = try SecureTokenGenerator.generate()
        let record = try await connections.open(
            peer: client,
            kernelUID: peer.uid,
            kernelPID: peer.processID,
            protocolVersion: request.protocolVersion,
            requestedCapabilities: request.capabilities ?? [],
            capabilityToken: token
        )
        connection = record
        return .success(id: request.id, result: .object([
            "connectionId": .string(record.id.uuidString),
            "connectionToken": .string(record.capabilityToken),
            "acceptedCapabilities": .array(record.capabilities.sorted { $0.rawValue < $1.rawValue }.map { .string($0.rawValue) }),
            "idleExpiresAt": .string(ISO8601DateFormatter().string(from: record.idleExpiresAt)),
        ]))
    }

    private func authorize(_ request: WireRequest) async throws -> HostRequestContext {
        guard let connection, let id = request.connectionID, id == connection.id,
              let token = request.connectionToken else {
            throw ConnectionValidationError.unauthenticated
        }
        guard let deadlineMs = request.deadlineUnixMs else {
            throw WireError(code: "deadline_required", message: "Post-hello requests require deadlineUnixMs")
        }
        let deadline = Date(timeIntervalSince1970: Double(deadlineMs) / 1_000)
        guard deadline > Date() else { throw WireError(code: "deadline_exceeded", message: "Request deadline elapsed", retryable: true) }
        let maximumDeadline = TimeInterval(WireDeadlinePolicy.maximumMilliseconds(for: request.method)) / 1_000 + 1
        guard deadline.timeIntervalSinceNow <= maximumDeadline else {
            throw WireError(
                code: "invalid_deadline",
                message: request.method == "requestAccess"
                    ? "Access request deadline exceeds the 300 second maximum"
                    : "Request deadline exceeds the 30 second maximum"
            )
        }
        let refreshed: ConnectionRecord
        do {
            refreshed = try await connections.touch(
                connectionID: id,
                capabilityToken: token,
                requiring: Self.requiredCapability(for: request.method)
            )
        } catch let error as ConnectionValidationError where
            error == .expired || error == .peerIdentityChanged {
            await handler.disconnect(connectionID: id)
            self.connection = nil
            throw error
        }
        self.connection = refreshed
        return HostRequestContext(requestID: request.id, connection: refreshed, deadline: deadline)
    }

    private static func requiredCapability(for method: String) -> HostCapability? {
        switch method {
        case "status", "listDisplays", "listApps": return .inventoryRead
        case "requestAccess": return .indicatorControl
        case "releaseAccess", "cancel": return .sessionStop
        case "approveRisk": return .riskApprove
        case "stop": return .sessionStop
        // Grant-level authorization further narrows capture and action methods.
        case "getState": return .windowCapture
        case "action": return .syntheticInput
        default: return nil
        }
    }
}

private final class SocketResponseWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    init(_ descriptor: Int32) { self.descriptor = descriptor }

    func send(_ response: WireResponse) {
        guard let data = try? WireCodec.encodeResponse(response) else { return }
        lock.lock()
        defer { lock.unlock() }
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let result = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if result <= 0 { break }
                sent += result
            }
        }
    }
}

private final class InflightRequestTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]

    func insert(_ task: Task<Void, Never>, id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard tasks[id] == nil else { return false }
        tasks[id] = task
        return true
    }
    func remove(_ id: String) { lock.lock(); tasks.removeValue(forKey: id); lock.unlock() }
    func cancel(_ id: String) -> Bool {
        lock.lock(); let task = tasks[id]; lock.unlock()
        task?.cancel()
        return task != nil
    }
    func cancelAll() {
        lock.lock(); let values = Array(tasks.values); tasks.removeAll(); lock.unlock()
        values.forEach { $0.cancel() }
    }
}

public final class HostSocketServer: @unchecked Sendable {
    private let configuration: SocketConfiguration
    private let authenticationToken: String
    private let peerInspector: SocketPeerInspecting
    private let peerVerifier: PeerCodeVerifying
    private let handler: HostMethodHandling
    private let connections: ConnectionRegistry
    private let replayGuard: HandshakeReplayGuard
    private let queue = DispatchQueue(label: "com.jmeguilos.computer-use-mcp.host.socket", qos: .userInitiated)
    private let maintenanceQueue = DispatchQueue(label: "com.jmeguilos.computer-use-mcp.host.maintenance", qos: .utility)
    private let maintenanceInterval: TimeInterval
    private let stateLock = NSLock()
    private var listener: Int32 = -1
    private var stopping = false
    private var maintenanceTimer: DispatchSourceTimer?

    public init(
        configuration: SocketConfiguration,
        authenticationToken: String,
        peerInspector: SocketPeerInspecting = DarwinSocketPeerInspector(),
        peerVerifier: PeerCodeVerifying,
        handler: HostMethodHandling,
        connections: ConnectionRegistry = ConnectionRegistry(),
        replayGuard: HandshakeReplayGuard = HandshakeReplayGuard(),
        maintenanceInterval: TimeInterval = 30
    ) {
        self.configuration = configuration
        self.authenticationToken = authenticationToken
        self.peerInspector = peerInspector
        self.peerVerifier = peerVerifier
        self.handler = handler
        self.connections = connections
        self.replayGuard = replayGuard
        self.maintenanceInterval = max(0.05, maintenanceInterval)
    }

    public func start() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard listener < 0 else { return }
        let path = configuration.socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw SocketServerError.socketPathTooLong
        }
        try removeStaleSocket(path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketServerError.socketCreationFailed }
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        do {
            try bindSocket(descriptor, path: path)
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else { throw SocketServerError.permissionUpdateFailed }
            guard Darwin.listen(descriptor, 16) == 0 else { throw SocketServerError.listenFailed }
        } catch {
            Darwin.close(descriptor)
            Darwin.unlink(path)
            throw error
        }
        stopping = false
        listener = descriptor
        queue.async { [weak self] in self?.acceptLoop(descriptor) }
        // accept(2) intentionally blocks the listener queue. Maintenance owns
        // a separate queue so inactivity revocation cannot be starved by it.
        let timer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        timer.schedule(deadline: .now() + maintenanceInterval, repeating: maintenanceInterval)
        timer.setEventHandler { [weak self] in self?.runMaintenance() }
        maintenanceTimer = timer
        timer.resume()
    }

    public func stop() {
        stateLock.lock()
        stopping = true
        let descriptor = listener
        listener = -1
        let timer = maintenanceTimer
        maintenanceTimer = nil
        stateLock.unlock()
        timer?.cancel()
        if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor) }
        Darwin.unlink(configuration.socketURL.path)
    }

    private func acceptLoop(_ descriptor: Int32) {
        while !isStopping {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 { if errno == EINTR { continue }; break }
            var noSigPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ descriptor: Int32) {
        let peer: SocketPeerCredentials
        do {
            peer = try peerInspector.credentials(socket: descriptor)
            guard peer.uid == UInt32(getuid()) else { throw LocalSecurityError.peerUIDMismatch }
            try peerVerifier.verify(peer)
        } catch {
            Darwin.close(descriptor)
            return
        }
        let session = WireConnectionSession(
            peer: peer,
            authenticationToken: authenticationToken,
            connections: connections,
            replayGuard: replayGuard,
            handler: handler
        )
        let writer = SocketResponseWriter(descriptor)
        let tasks = InflightRequestTasks()
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 32 * 1_024)
        readLoop: while true {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.count > WireCodec.maximumLineBytes { break }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                let request: WireRequest
                do { request = try WireCodec.decodeRequest(Data(line)) }
                catch {
                    writer.send(.failure(id: "invalid", error: WireError(code: "malformed_frame", message: "Invalid request frame")))
                    break readLoop
                }
                if request.method == "cancel" {
                    Task {
                        do {
                            let requestID = try await session.validateCancel(request)
                            let canceled = tasks.cancel(requestID)
                            writer.send(.success(id: request.id, result: .object(["canceled": .bool(canceled)])))
                        } catch {
                            writer.send(.failure(id: request.id, error: WireErrorMapping.map(error)))
                        }
                    }
                    continue
                }
                let task = Task {
                    let response = await session.dispatch(request)
                    writer.send(response)
                    tasks.remove(request.id)
                }
                if !tasks.insert(task, id: request.id) {
                    task.cancel()
                    writer.send(.failure(id: request.id, error: WireError(code: "duplicate_request_id", message: "Request is already in flight")))
                }
            }
        }
        tasks.cancelAll()
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        let semaphore = DispatchSemaphore(value: 0)
        Task { await session.close(); semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    private var isStopping: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopping
    }

    private func runMaintenance() {
        Task { [connections, handler] in
            let expiredConnections = await connections.revokeExpired()
            for connectionID in expiredConnections { await handler.disconnect(connectionID: connectionID) }
            await handler.maintenance(now: Date())
        }
    }

    private func removeStaleSocket(_ path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT { return }
            throw SocketServerError.metadataUnavailable
        }
        guard status.st_uid == getuid(), (status.st_mode & S_IFMT) == S_IFSOCK else {
            throw SocketServerError.unsafeExistingPath
        }
        guard Darwin.unlink(path) == 0 else { throw SocketServerError.unlinkFailed }
    }

    private func bindSocket(_ descriptor: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, length)
            }
        }
        guard result == 0 else { throw SocketServerError.bindFailed }
    }
}

public enum SocketServerError: String, Error, Equatable, Sendable {
    case socketPathTooLong
    case socketCreationFailed
    case bindFailed
    case listenFailed
    case permissionUpdateFailed
    case metadataUnavailable
    case unsafeExistingPath
    case unlinkFailed
}
