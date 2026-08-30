import Darwin
import Foundation

public struct HostPreferences: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentOnboardingRevision = 1
    public static let defaults = HostPreferences(
        schemaVersion: currentSchemaVersion,
        onboardingRevision: 0,
        anyAppControlEnabled: false
    )

    public let schemaVersion: Int
    public let onboardingRevision: Int
    public let anyAppControlEnabled: Bool

    public init(
        schemaVersion: Int = HostPreferences.currentSchemaVersion,
        onboardingRevision: Int = 0,
        anyAppControlEnabled: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.onboardingRevision = onboardingRevision
        self.anyAppControlEnabled = anyAppControlEnabled
    }
}

public actor PersistentHostPreferencesStore {
    private static let maximumFileBytes = 16_384
    private static let fileMode = S_IRUSR | S_IWUSR
    private static let directoryMode = S_IRWXU

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("ComputerUseMCP/preferences/host.json")
    }

    private let url: URL
    private var preferences: HostPreferences

    public init(url: URL) throws {
        self.url = url
        try Self.prepareParentDirectory(for: url)
        let directoryDescriptor = try Self.openParentDirectory(for: url)
        defer { close(directoryDescriptor) }

        if let data = try Self.readFile(
            named: try Self.validatedFileName(for: url),
            directoryDescriptor: directoryDescriptor
        ) {
            self.preferences = try Self.decodeAndValidate(data)
        } else {
            let defaults = HostPreferences.defaults
            try Self.createInitialFile(
                named: try Self.validatedFileName(for: url),
                data: try Self.encode(defaults),
                directoryDescriptor: directoryDescriptor
            )
            self.preferences = defaults
        }
    }

    public func snapshot() -> HostPreferences { preferences }

    public func setAnyAppControlEnabled(_ enabled: Bool) throws {
        let updated = HostPreferences(
            schemaVersion: preferences.schemaVersion,
            onboardingRevision: preferences.onboardingRevision,
            anyAppControlEnabled: enabled
        )
        try persist(updated)
        preferences = updated
    }

    /// Runtime-only emergency latch for a failed disable write. This never
    /// pretends persistence succeeded; it simply keeps this host process
    /// fail-closed until the protected file can be repaired or updated.
    public func forceDisableForCurrentProcess() {
        preferences = HostPreferences(
            schemaVersion: preferences.schemaVersion,
            onboardingRevision: preferences.onboardingRevision,
            anyAppControlEnabled: false
        )
    }

    public func setOnboardingRevision(_ revision: Int) throws {
        guard (0...HostPreferences.currentOnboardingRevision).contains(revision) else {
            throw HostPreferencesStoreError.invalidContents
        }
        let updated = HostPreferences(
            schemaVersion: preferences.schemaVersion,
            onboardingRevision: revision,
            anyAppControlEnabled: preferences.anyAppControlEnabled
        )
        try persist(updated)
        preferences = updated
    }

    public func markCurrentOnboardingCompleted() throws {
        try setOnboardingRevision(HostPreferences.currentOnboardingRevision)
    }

    private func persist(_ updated: HostPreferences) throws {
        try Self.validate(updated)
        let directoryDescriptor = try Self.openParentDirectory(for: url)
        defer { close(directoryDescriptor) }
        let fileName = try Self.validatedFileName(for: url)

        // Refuse to recreate or replace a preference file that was deleted,
        // loosened, or changed to a symbolic link after initialization.
        guard try Self.readFile(
            named: fileName,
            directoryDescriptor: directoryDescriptor
        ) != nil else {
            throw HostPreferencesStoreError.unsafeFile
        }

        let temporaryName = ".host.\(UUID().uuidString).tmp"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            Self.fileMode
        )
        guard descriptor >= 0 else { throw HostPreferencesStoreError.persistenceFailed }
        var removeTemporary = true
        defer {
            close(descriptor)
            if removeTemporary {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        try Self.validateFileDescriptor(descriptor)
        let data = try Self.encode(updated)
        guard Self.writeAll(data, descriptor: descriptor), fsync(descriptor) == 0 else {
            throw HostPreferencesStoreError.persistenceFailed
        }
        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, fileName) == 0 else {
            throw HostPreferencesStoreError.persistenceFailed
        }
        removeTemporary = false

        guard let persisted = try Self.readFile(
            named: fileName,
            directoryDescriptor: directoryDescriptor
        ), try Self.decodeAndValidate(persisted) == updated else {
            throw HostPreferencesStoreError.persistenceFailed
        }
        _ = fsync(directoryDescriptor)
    }

    private static func prepareParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        var status = stat()
        if lstat(parent.path, &status) == 0 {
            try validateDirectoryStatus(status)
            return
        }
        guard errno == ENOENT else { throw HostPreferencesStoreError.unsafeDirectory }
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int(directoryMode))]
            )
        } catch {
            throw HostPreferencesStoreError.creationFailed
        }
        let descriptor = open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw HostPreferencesStoreError.creationFailed }
        defer { close(descriptor) }
        guard fstat(descriptor, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFDIR,
              fchmod(descriptor, directoryMode) == 0,
              fstat(descriptor, &status) == 0 else {
            throw HostPreferencesStoreError.creationFailed
        }
        try validateDirectoryStatus(status)
    }

    private static func openParentDirectory(for url: URL) throws -> Int32 {
        let descriptor = open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw HostPreferencesStoreError.unsafeDirectory }
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw HostPreferencesStoreError.unsafeDirectory
            }
            try validateDirectoryStatus(status)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func validateDirectoryStatus(_ status: stat) throws {
        guard status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_mode & 0o777 == directoryMode else {
            throw HostPreferencesStoreError.unsafeDirectory
        }
    }

    private static func validatedFileName(for url: URL) throws -> String {
        let fileName = url.lastPathComponent
        guard !fileName.isEmpty, fileName != ".", fileName != "..", !fileName.contains("/") else {
            throw HostPreferencesStoreError.unsafeFile
        }
        return fileName
    }

    private static func readFile(named fileName: String, directoryDescriptor: Int32) throws -> Data? {
        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw HostPreferencesStoreError.unsafeFile
        }
        defer { close(descriptor) }

        let before = try validatedFileStatus(descriptor)
        guard before.st_size >= 0, before.st_size <= off_t(maximumFileBytes) else {
            throw HostPreferencesStoreError.unsafeFile
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= maximumFileBytes {
            let remaining = maximumFileBytes + 1 - data.count
            let requested = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw HostPreferencesStoreError.unsafeFile
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumFileBytes else { throw HostPreferencesStoreError.unsafeFile }

        let after = try validatedFileStatus(descriptor)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
            throw HostPreferencesStoreError.unsafeFile
        }
        return data
    }

    private static func validatedFileStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1,
              status.st_mode & 0o777 == fileMode else {
            throw HostPreferencesStoreError.unsafeFile
        }
        return status
    }

    private static func validateFileDescriptor(_ descriptor: Int32) throws {
        _ = try validatedFileStatus(descriptor)
    }

    private static func createInitialFile(
        named fileName: String,
        data: Data,
        directoryDescriptor: Int32
    ) throws {
        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            fileMode
        )
        guard descriptor >= 0 else { throw HostPreferencesStoreError.creationFailed }
        defer { close(descriptor) }
        do {
            try validateFileDescriptor(descriptor)
        } catch {
            _ = unlinkat(directoryDescriptor, fileName, 0)
            throw error
        }
        guard writeAll(data, descriptor: descriptor), fsync(descriptor) == 0 else {
            _ = unlinkat(directoryDescriptor, fileName, 0)
            throw HostPreferencesStoreError.creationFailed
        }
        _ = fsync(directoryDescriptor)
    }

    private static func encode(_ preferences: HostPreferences) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(preferences)
        } catch {
            throw HostPreferencesStoreError.invalidContents
        }
    }

    private static func decodeAndValidate(_ data: Data) throws -> HostPreferences {
        let decoded: HostPreferences
        do {
            decoded = try JSONDecoder().decode(HostPreferences.self, from: data)
        } catch {
            throw HostPreferencesStoreError.invalidContents
        }
        try validate(decoded)
        return decoded
    }

    private static func validate(_ preferences: HostPreferences) throws {
        guard preferences.schemaVersion == HostPreferences.currentSchemaVersion else {
            throw HostPreferencesStoreError.unsupportedSchemaVersion
        }
        guard (0...HostPreferences.currentOnboardingRevision).contains(preferences.onboardingRevision) else {
            throw HostPreferencesStoreError.invalidContents
        }
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

public enum HostPreferencesStoreError: String, Error, Equatable, Sendable {
    case creationFailed
    case persistenceFailed
    case unsafeDirectory
    case unsafeFile
    case invalidContents
    case unsupportedSchemaVersion
}
