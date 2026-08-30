import Darwin
import Foundation

public struct PersistentAppConsent: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let signingIdentity: String
    public let capabilities: Set<PublicCapability>
    public let updatedAt: Date
}

public actor PersistentAppConsentStore {
    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("ComputerUseMCP/consent/apps.json")
    }

    private let url: URL
    private var records: [String: PersistentAppConsent]

    public init(url: URL) throws {
        self.url = url
        let parent = url.deletingLastPathComponent()
        var parentStatus = stat()
        if lstat(parent.path, &parentStatus) == 0 {
            guard parentStatus.st_uid == getuid(), parentStatus.st_mode & S_IFMT == S_IFDIR,
                  parentStatus.st_mode & 0o777 == S_IRWXU else { throw ConsentStoreError.unsafeDirectory }
        } else {
            guard errno == ENOENT else { throw ConsentStoreError.unsafeDirectory }
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int(S_IRWXU))]
            )
            guard chmod(parent.path, S_IRWXU) == 0 else { throw ConsentStoreError.permissionUpdateFailed }
        }
        let existing: Data?
        do {
            existing = try SecureFileIO.readIfExists(
                path: url.path,
                requiredMode: S_IRUSR | S_IWUSR,
                maximumBytes: 1_048_576
            )
        } catch {
            throw ConsentStoreError.unsafeFile
        }
        if let data = existing {
            let values = try JSONDecoder.consent.decode([PersistentAppConsent].self, from: data)
            self.records = Dictionary(uniqueKeysWithValues: values.map { (Self.key($0.bundleIdentifier, $0.signingIdentity), $0) })
        } else {
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw ConsentStoreError.creationFailed }
            defer { close(descriptor) }
            do { try SecureFileIO.validateDescriptor(descriptor, requiredMode: S_IRUSR | S_IWUSR) }
            catch { throw ConsentStoreError.unsafeFile }
            guard Self.writeAll(Data("[]".utf8), descriptor: descriptor), fsync(descriptor) == 0 else {
                throw ConsentStoreError.creationFailed
            }
            self.records = [:]
        }
    }

    public func allows(window: WindowIdentity, capabilities: Set<PublicCapability>) -> Bool {
        guard let record = records[Self.key(window.bundleIdentifier, window.signingIdentity)] else { return false }
        return capabilities.isSubset(of: record.capabilities)
    }

    public func record(window: WindowIdentity, capabilities: Set<PublicCapability>, now: Date = Date()) throws {
        let key = Self.key(window.bundleIdentifier, window.signingIdentity)
        let combined = records[key]?.capabilities.union(capabilities) ?? capabilities
        records[key] = PersistentAppConsent(
            bundleIdentifier: window.bundleIdentifier,
            signingIdentity: window.signingIdentity,
            capabilities: combined,
            updatedAt: now
        )
        try persist()
    }

    public func revoke(bundleIdentifier: String, signingIdentity: String) throws {
        records.removeValue(forKey: Self.key(bundleIdentifier, signingIdentity))
        try persist()
    }

    public func revokeAll() throws {
        records.removeAll()
        try persist()
    }

    public func all() -> [PersistentAppConsent] {
        records.values.sorted { left, right in
            if left.bundleIdentifier == right.bundleIdentifier { return left.signingIdentity < right.signingIdentity }
            return left.bundleIdentifier < right.bundleIdentifier
        }
    }

    private func persist() throws {
        let data = try JSONEncoder.consent.encode(records.values.sorted { $0.bundleIdentifier < $1.bundleIdentifier })
        let parent = url.deletingLastPathComponent()
        var parentStatus = stat()
        guard lstat(parent.path, &parentStatus) == 0,
              parentStatus.st_uid == getuid(),
              parentStatus.st_mode & S_IFMT == S_IFDIR,
              parentStatus.st_mode & 0o777 == S_IRWXU else {
            throw ConsentStoreError.unsafeDirectory
        }
        do {
            guard try SecureFileIO.readIfExists(
                path: url.path,
                requiredMode: S_IRUSR | S_IWUSR,
                maximumBytes: 1_048_576
            ) != nil else { throw ConsentStoreError.unsafeFile }
        } catch let error as ConsentStoreError {
            throw error
        } catch {
            throw ConsentStoreError.unsafeFile
        }

        let temporary = parent.appendingPathComponent(".apps.\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw ConsentStoreError.creationFailed }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary { unlink(temporary.path) }
        }
        do { try SecureFileIO.validateDescriptor(descriptor, requiredMode: S_IRUSR | S_IWUSR) }
        catch { throw ConsentStoreError.unsafeFile }
        guard Self.writeAll(data, descriptor: descriptor), fsync(descriptor) == 0 else {
            throw ConsentStoreError.creationFailed
        }
        guard rename(temporary.path, url.path) == 0 else { throw ConsentStoreError.creationFailed }
        shouldRemoveTemporary = false
    }

    private static func key(_ bundle: String, _ signing: String) -> String { "\(bundle)\n\(signing)" }

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

private extension JSONEncoder {
    static var consent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var consent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum ConsentStoreError: String, Error, Equatable, Sendable {
    case creationFailed
    case permissionUpdateFailed
    case unsafeFile
    case unsafeDirectory
}
