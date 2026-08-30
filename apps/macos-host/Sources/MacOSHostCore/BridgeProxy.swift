import Darwin
import Foundation

public final class BridgeProxy: @unchecked Sendable {
    private let configuration: SocketConfiguration
    private let input: FileHandle
    private let output: FileHandle
    private let diagnostics: FileHandle
    private let writeLock = NSLock()
    private var socketDescriptor: Int32 = -1

    public init(
        configuration: SocketConfiguration,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        diagnostics: FileHandle = .standardError
    ) {
        self.configuration = configuration
        self.input = input
        self.output = output
        self.diagnostics = diagnostics
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

    private func transform(_ data: Data, authenticationToken: String, first: Bool) throws -> Data {
        guard data.count <= WireCodec.maximumLineBytes else { throw BridgeProxyError.frameTooLarge }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String,
              let identifier = object["id"] as? String,
              !identifier.isEmpty else { throw BridgeProxyError.malformedFrame }
        let allowed = Set(["hello", "status", "listDisplays", "listApps", "requestAccess", "releaseAccess", "getState", "action", "approveRisk", "stop", "cancel"])
        guard allowed.contains(method) else { throw BridgeProxyError.unsupportedMethod }
        if first {
            guard method == "hello" else { throw BridgeProxyError.helloRequired }
            let incomingClient = object["client"] as? [String: Any] ?? [:]
            object["auth"] = ["token": authenticationToken]
            object["client"] = [
                "name": incomingClient["name"] as? String ?? "computer-use-mcp-server",
                "instanceId": incomingClient["instanceId"] as? String ?? UUID().uuidString,
                "uid": UInt32(getuid()),
                "pid": ProcessInfo.processInfo.processIdentifier,
            ]
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
