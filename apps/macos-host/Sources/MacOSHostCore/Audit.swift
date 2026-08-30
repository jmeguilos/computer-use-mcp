import CryptoKit
import Darwin
import Foundation

public struct RedactedField: Codable, Equatable, Sendable {
    public let sha256: String
    public let characterCount: Int
}

public struct AuditTarget: Codable, Equatable, Sendable {
    public let bundleIdentifier: RedactedField
    public let title: RedactedField?
    public let windowID: UInt32?
    public let displayID: UInt32?
}

public enum AuditResult: String, Codable, Sendable {
    case allowed
    case denied
    case failed
    case canceled
}

public struct AuditEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let connectionID: UUID
    public let requestID: String
    public let action: String
    public let riskTier: RiskTier
    public let result: AuditResult
    public let reasonCode: String?
    public let target: AuditTarget?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        connectionID: UUID,
        requestID: String,
        action: String,
        riskTier: RiskTier,
        result: AuditResult,
        reasonCode: String?,
        target: AuditTarget?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.connectionID = connectionID
        self.requestID = requestID
        self.action = action
        self.riskTier = riskTier
        self.result = result
        self.reasonCode = reasonCode
        self.target = target
    }
}

public struct AuditRedactor: Sendable {
    private let salt: Data

    public init(salt: Data) {
        self.salt = salt
    }

    public func redact(_ value: String) -> RedactedField {
        var bytes = salt
        bytes.append(contentsOf: value.utf8)
        let digest = SHA256.hash(data: bytes)
        return RedactedField(
            sha256: digest.map { String(format: "%02x", $0) }.joined(),
            characterCount: value.count
        )
    }

    public func target(window: WindowDescriptor) -> AuditTarget {
        AuditTarget(
            bundleIdentifier: redact(window.identity.bundleIdentifier),
            title: window.title.map(redact),
            windowID: window.identity.windowID,
            displayID: nil
        )
    }
}

public struct AuditRetentionPolicy: Equatable, Sendable {
    public let maximumAge: TimeInterval
    public let maximumEntries: Int

    public init(maximumAge: TimeInterval = 7 * 24 * 60 * 60, maximumEntries: Int = 10_000) {
        self.maximumAge = maximumAge
        self.maximumEntries = maximumEntries
    }

    public func retaining(_ events: [AuditEvent], now: Date) -> [AuditEvent] {
        guard maximumEntries > 0, maximumAge > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-maximumAge)
        let recent = events.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
        return Array(recent.suffix(maximumEntries))
    }
}

public final class FileAuditStore: @unchecked Sendable {
    private static let maximumFileBytes = 16 * 1_024 * 1_024
    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("ComputerUseMCP/audit/events.jsonl")
    }

    private let url: URL
    private let retention: AuditRetentionPolicy
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL, retention: AuditRetentionPolicy = AuditRetentionPolicy()) throws {
        self.url = url
        self.retention = retention
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try Self.prepare(parent: url.deletingLastPathComponent(), file: url)
        // Enforce retention when the host starts, not only after a later
        // action happens to append another event.
        try prune(now: Date())
    }

    public func append(_ event: AuditEvent, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.validateParentPath(url.deletingLastPathComponent())
        var events = try loadUnlocked()
        events.append(event)
        events = retention.retaining(events, now: now)
        try writeUnlocked(events)
    }

    public func prune(now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.validateParentPath(url.deletingLastPathComponent())
        let events = try loadUnlocked()
        let retained = retention.retaining(events, now: now)
        if retained != events { try writeUnlocked(retained) }
    }

    public func load() throws -> [AuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    private func loadUnlocked() throws -> [AuditEvent] {
        let data: Data
        do {
            guard let opened = try SecureFileIO.readIfExists(
                path: url.path,
                requiredMode: S_IRUSR | S_IWUSR,
                maximumBytes: Self.maximumFileBytes
            ) else { throw AuditStoreError.unsafeFile }
            data = opened
        } catch let error as AuditStoreError {
            throw error
        } catch {
            throw AuditStoreError.unsafeFile
        }
        guard !data.isEmpty else { return [] }
        return try data.split(separator: 0x0A).map { try decoder.decode(AuditEvent.self, from: Data($0)) }
    }

    private func writeUnlocked(_ events: [AuditEvent]) throws {
        let lines = try events.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let content = (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).data(using: .utf8)!
        guard content.count <= Self.maximumFileBytes else { throw AuditStoreError.fileTooLarge }
        try Self.replace(file: url, with: content)
    }

    private static func prepare(parent: URL, file: URL) throws {
        var parentStatus = stat()
        if lstat(parent.path, &parentStatus) == 0 {
            try validateParent(parentStatus)
        } else {
            guard errno == ENOENT else { throw AuditStoreError.unsafeParent }
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int(S_IRWXU))]
            )
            guard chmod(parent.path, S_IRWXU) == 0 else { throw AuditStoreError.permissionUpdateFailed }
            guard lstat(parent.path, &parentStatus) == 0 else { throw AuditStoreError.unsafeParent }
            try validateParent(parentStatus)
        }
        let existing: Data?
        do {
            existing = try SecureFileIO.readIfExists(
                path: file.path,
                requiredMode: S_IRUSR | S_IWUSR,
                maximumBytes: maximumFileBytes
            )
        } catch {
            throw AuditStoreError.unsafeFile
        }
        if existing == nil {
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw AuditStoreError.creationFailed }
            do { try SecureFileIO.validateDescriptor(descriptor, requiredMode: S_IRUSR | S_IWUSR) }
            catch { close(descriptor); throw AuditStoreError.unsafeFile }
            close(descriptor)
        }
    }

    private static func validateParentPath(_ parent: URL) throws {
        var parentStatus = stat()
        guard lstat(parent.path, &parentStatus) == 0 else { throw AuditStoreError.unsafeParent }
        try validateParent(parentStatus)
    }

    private static func validateParent(_ status: stat) throws {
        guard status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_mode & 0o777 == S_IRWXU else { throw AuditStoreError.unsafeParent }
    }

    private static func replace(file: URL, with data: Data) throws {
        let parent = file.deletingLastPathComponent()
        try validateParentPath(parent)
        let temporary = parent.appendingPathComponent(".events.\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw AuditStoreError.creationFailed }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove { unlink(temporary.path) }
        }
        do { try SecureFileIO.validateDescriptor(descriptor, requiredMode: S_IRUSR | S_IWUSR) }
        catch { throw AuditStoreError.unsafeFile }
        guard writeAll(data, descriptor: descriptor), fsync(descriptor) == 0 else {
            throw AuditStoreError.creationFailed
        }
        guard rename(temporary.path, file.path) == 0 else { throw AuditStoreError.creationFailed }
        shouldRemove = false
    }

    private static func writeAll(_ data: Data, descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

public enum AuditStoreError: String, Error, Equatable {
    case creationFailed
    case permissionUpdateFailed
    case unsafeParent
    case unsafeFile
    case fileTooLarge
}
