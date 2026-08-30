import AppKit
import Darwin
import Foundation

public struct HarnessProcessIdentity: Equatable, Sendable {
    public let name: String
    public let processID: Int32
    public let bundleIdentifier: String
    public let signingIdentity: String
    public let processStartTimeUnixMs: Int64

    public init(
        name: String,
        processID: Int32,
        bundleIdentifier: String,
        signingIdentity: String,
        processStartTimeUnixMs: Int64
    ) {
        self.name = name
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.signingIdentity = signingIdentity
        self.processStartTimeUnixMs = processStartTimeUnixMs
    }
}

enum BridgeClientIdentityPolicy {
    static func makePeer(
        harness: HarnessProcessIdentity?,
        bridgeUID: UInt32,
        bridgeProcessID: Int32,
        bridgeInstanceID: String
    ) -> PeerIdentity {
        guard let harness else {
            return PeerIdentity(
                uid: bridgeUID,
                processID: bridgeProcessID,
                name: "Unidentified local MCP harness",
                instanceID: bridgeInstanceID
            )
        }
        return PeerIdentity(
            uid: bridgeUID,
            processID: bridgeProcessID,
            name: sanitizedPresentationName(harness.name),
            instanceID: bridgeInstanceID,
            harnessProcessID: harness.processID,
            harnessBundleIdentifier: harness.bundleIdentifier,
            harnessSigningIdentity: harness.signingIdentity,
            harnessProcessStartTimeUnixMs: harness.processStartTimeUnixMs,
            harnessIdentityVerified: true
        )
    }

    static func sanitizedPresentationName(_ name: String) -> String {
        let normalized = name.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Unidentified local MCP harness" }
        return String(normalized.prefix(128))
    }
}

enum HarnessApplicationActivationPolicy: Equatable, Sendable {
    case regular
    case accessory
    case prohibited
}

struct HarnessApplicationProcessSnapshot: Equatable, Sendable {
    let name: String?
    let bundleIdentifier: String?
    let signingIdentity: String?
    let processStartTimeUnixMs: Int64?
    let activationPolicy: HarnessApplicationActivationPolicy
}

protocol HarnessProcessAncestryInspecting: Sendable {
    func applicationSnapshot(processID: Int32) -> HarnessApplicationProcessSnapshot?
    func parentProcessID(of processID: Int32) -> Int32?
}

struct LiveHarnessProcessAncestryInspector: HarnessProcessAncestryInspecting {
    func applicationSnapshot(processID: Int32) -> HarnessApplicationProcessSnapshot? {
        guard let running = NSRunningApplication(processIdentifier: processID) else { return nil }
        let activationPolicy: HarnessApplicationActivationPolicy
        switch running.activationPolicy {
        case .regular: activationPolicy = .regular
        case .accessory: activationPolicy = .accessory
        case .prohibited: activationPolicy = .prohibited
        @unknown default: activationPolicy = .prohibited
        }
        return HarnessApplicationProcessSnapshot(
            name: running.localizedName,
            bundleIdentifier: running.bundleIdentifier,
            signingIdentity: ProcessCodeIdentity.designatedRequirementDigest(processID: processID),
            processStartTimeUnixMs: running.launchDate.map {
                Int64($0.timeIntervalSince1970 * 1_000)
            },
            activationPolicy: activationPolicy
        )
    }

    func parentProcessID(of processID: Int32) -> Int32? {
        var information = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        guard sysctl(&mib, u_int(mib.count), &information, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return information.kp_eproc.e_ppid
    }
}

enum HarnessProcessIdentityResolver {
    static let maximumDepth = 32

    static func resolve(
        startingAt processID: Int32 = getppid(),
        inspector: any HarnessProcessAncestryInspecting = LiveHarnessProcessAncestryInspector()
    ) -> HarnessProcessIdentity? {
        var current = processID
        var visited = Set<Int32>()
        for _ in 0..<maximumDepth {
            guard current > 1, visited.insert(current).inserted else { break }
            // Accessory processes are frequently Electron/Chromium helpers
            // whose bundle and PID do not own the harness's regular windows.
            // Binding one would make main-app self-exclusion incomplete. V1
            // therefore accepts only the nearest fully valid regular GUI app;
            // an accessory-only ancestry remains unidentified and cannot gain
            // target authority.
            if let snapshot = inspector.applicationSnapshot(processID: current),
               snapshot.activationPolicy == .regular {
                // A nearer regular GUI process is the harness candidate even
                // when one of its binding attributes is unavailable. Falling
                // through to an outer launcher would exclude the wrong app
                // and could permit control of the nearer GUI, so fail closed.
                guard let bundleIdentifier = snapshot.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !bundleIdentifier.isEmpty,
                      let signingIdentity = snapshot.signingIdentity?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !signingIdentity.isEmpty,
                      let processStartTimeUnixMs = snapshot.processStartTimeUnixMs,
                      processStartTimeUnixMs > 0 else { return nil }
                return HarnessProcessIdentity(
                    name: snapshot.name ?? bundleIdentifier,
                    processID: current,
                    bundleIdentifier: bundleIdentifier,
                    signingIdentity: signingIdentity,
                    processStartTimeUnixMs: processStartTimeUnixMs
                )
            }
            guard let parent = inspector.parentProcessID(of: current), parent != current else { break }
            current = parent
        }
        return nil
    }
}

public final class BridgeProxy: @unchecked Sendable {
    private let configuration: SocketConfiguration
    private let input: FileHandle
    private let output: FileHandle
    private let diagnostics: FileHandle
    private let presentedPeer: PeerIdentity
    private let serverPeerInspector: any SocketPeerInspecting
    private let serverPeerVerifier: (any PeerCodeVerifying)?
    private let writeLock = NSLock()
    private var socketDescriptor: Int32 = -1

    public convenience init(
        configuration: SocketConfiguration,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        diagnostics: FileHandle = .standardError
    ) {
        self.init(
            configuration: configuration,
            input: input,
            output: output,
            diagnostics: diagnostics,
            harnessIdentity: HarnessProcessIdentityResolver.resolve(),
            bridgeInstanceID: UUID().uuidString,
            serverPeerInspector: DarwinSocketPeerInspector(),
            serverPeerVerifier: nil
        )
    }

    init(
        configuration: SocketConfiguration,
        input: FileHandle,
        output: FileHandle,
        diagnostics: FileHandle,
        harnessIdentity: HarnessProcessIdentity?,
        bridgeInstanceID: String,
        serverPeerInspector: any SocketPeerInspecting = DarwinSocketPeerInspector(),
        serverPeerVerifier: (any PeerCodeVerifying)? = nil
    ) {
        self.configuration = configuration
        self.input = input
        self.output = output
        self.diagnostics = diagnostics
        self.serverPeerInspector = serverPeerInspector
        self.serverPeerVerifier = serverPeerVerifier
        self.presentedPeer = BridgeClientIdentityPolicy.makePeer(
            harness: harnessIdentity,
            bridgeUID: UInt32(getuid()),
            bridgeProcessID: ProcessInfo.processInfo.processIdentifier,
            bridgeInstanceID: bridgeInstanceID
        )
    }

    public func run() throws {
        let token = try RuntimeCredentialStore(configuration: configuration).loadExisting()
        let descriptor = try connectSocket(path: configuration.socketURL.path)
        socketDescriptor = descriptor
        defer {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            socketDescriptor = -1
        }
        try authenticateServer(socket: descriptor)

        let stdinReader = BoundedLineReader(fileHandle: input, maximumBytes: WireCodec.maximumLineBytes)
        guard let first = try stdinReader.nextLine() else { throw BridgeProxyError.helloRequired }
        let hello = try transform(first, authenticationToken: token, first: true)
        try writeToSocket(hello, descriptor: descriptor)

        let responseFinished = DispatchSemaphore(value: 0)
        let responseError = LockedBox<Error?>(nil)
        DispatchQueue.global(qos: .userInitiated).async { [output] in
            defer { responseFinished.signal() }
            do {
                let reader = BoundedSocketLineReader(descriptor: descriptor, maximumBytes: WireCodec.maximumLineBytes)
                while let line = try reader.nextLine() {
                    try output.write(contentsOf: line + Data([0x0A]))
                }
            } catch {
                responseError.set(error)
            }
        }

        do {
            while let line = try stdinReader.nextLine() {
                let transformed = try transform(line, authenticationToken: token, first: false)
                try writeToSocket(transformed, descriptor: descriptor)
            }
            Darwin.shutdown(descriptor, SHUT_WR)
            _ = responseFinished.wait(timeout: .now() + 2)
            if let error = responseError.get() { throw error }
        } catch {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            throw error
        }
    }

    func authenticateServer(socket: Int32) throws {
        let peer = try serverPeerInspector.credentials(socket: socket)
        guard peer.uid == UInt32(getuid()), peer.processID > 1,
              !peer.auditToken.isEmpty else {
            throw LocalSecurityError.peerCredentialUnavailable
        }
        let verifier = try serverPeerVerifier ?? BridgeHostPeerVerifierFactory.make(
            configuration: configuration
        )
        try verifier.verify(peer)
    }

    func transform(_ data: Data, authenticationToken: String, first: Bool) throws -> Data {
        guard data.count <= WireCodec.maximumLineBytes else { throw BridgeProxyError.frameTooLarge }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String,
              let identifier = object["id"] as? String,
              !identifier.isEmpty else { throw BridgeProxyError.malformedFrame }
        let allowed = Set(["hello", "status", "listDisplays", "listApps", "requestAccess", "releaseAccess", "getState", "action", "approveRisk", "stop", "cancel"])
        guard allowed.contains(method) else { throw BridgeProxyError.unsupportedMethod }
        if first {
            guard method == "hello" else { throw BridgeProxyError.helloRequired }
            object["auth"] = ["token": authenticationToken]
            let peerData = try JSONEncoder().encode(presentedPeer)
            guard let peerObject = try JSONSerialization.jsonObject(with: peerData) as? [String: Any] else {
                throw BridgeProxyError.malformedFrame
            }
            // Caller-provided names and instance IDs are untrusted display
            // strings. The bridge derives the nearest verifiable GUI ancestor
            // and creates its own per-process instance identifier.
            object["client"] = peerObject
            object["nonce"] = try SecureTokenGenerator.generate()
            object.removeValue(forKey: "deadlineUnixMs")
        } else {
            guard method != "hello" else { throw BridgeProxyError.duplicateHello }
            object.removeValue(forKey: "auth")
            object.removeValue(forKey: "client")
            object.removeValue(forKey: "nonce")
            let params = object["params"] as? [String: Any]
            let requested = params?["timeoutMs"] as? NSNumber
            let maximum = WireDeadlinePolicy.maximumMilliseconds(for: method)
            let defaultTimeout = WireDeadlinePolicy.defaultMilliseconds(for: method)
            let timeout = min(maximum, max(100, requested?.intValue ?? defaultTimeout))
            object["deadlineUnixMs"] = Int64(Date().timeIntervalSince1970 * 1_000) + Int64(timeout)
        }
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard encoded.count <= WireCodec.maximumLineBytes else { throw BridgeProxyError.frameTooLarge }
        return encoded
    }

    private func connectSocket(path: String) throws -> Int32 {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw BridgeProxyError.socketPathTooLong
        }
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_uid == getuid(),
              (status.st_mode & S_IFMT) == S_IFSOCK,
              status.st_mode & 0o777 == (S_IRUSR | S_IWUSR) else {
            throw BridgeProxyError.unsafeSocket
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BridgeProxyError.connectionFailed }
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else { Darwin.close(descriptor); throw BridgeProxyError.connectionFailed }
        return descriptor
    }

    private func writeToSocket(_ data: Data, descriptor: Int32) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var framed = data
        framed.append(0x0A)
        let wroteAll = framed.withUnsafeBytes { bytes -> Bool in
            var written = 0
            while written < bytes.count {
                let result = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written, 0)
                if result <= 0 { return false }
                written += result
            }
            return true
        }
        guard wroteAll else { throw BridgeProxyError.connectionClosed }
    }

    public func writeDiagnostic(_ message: String) {
        // Diagnostics deliberately contain no envelopes, params or token values.
        try? diagnostics.write(contentsOf: Data(("ComputerUseMCPBridge: \(message)\n").utf8))
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}

private final class BoundedLineReader {
    private let fileHandle: FileHandle
    private let maximumBytes: Int
    private var buffer = Data()
    init(fileHandle: FileHandle, maximumBytes: Int) { self.fileHandle = fileHandle; self.maximumBytes = maximumBytes }

    func nextLine() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                return line
            }
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let line = buffer; buffer.removeAll(); return line
            }
            buffer.append(chunk)
            guard buffer.count <= maximumBytes else { throw BridgeProxyError.frameTooLarge }
        }
    }
}

private final class BoundedSocketLineReader {
    private let descriptor: Int32
    private let maximumBytes: Int
    private var buffer = Data()
    init(descriptor: Int32, maximumBytes: Int) { self.descriptor = descriptor; self.maximumBytes = maximumBytes }

    func nextLine() throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: 32 * 1_024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                return line
            }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count == 0 { return buffer.isEmpty ? nil : buffer }
            if count < 0 { if errno == EINTR { continue }; throw BridgeProxyError.connectionClosed }
            buffer.append(contentsOf: chunk[0..<count])
            guard buffer.count <= maximumBytes else { throw BridgeProxyError.frameTooLarge }
        }
    }
}

public enum BridgeProxyError: String, Error, Equatable, Sendable {
    case frameTooLarge
    case malformedFrame
    case unsupportedMethod
    case helloRequired
    case duplicateHello
    case socketPathTooLong
    case unsafeSocket
    case connectionFailed
    case connectionClosed
}
