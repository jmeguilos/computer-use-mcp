import Darwin
import Foundation

public enum PersistentAppConsentPolicy: String, Codable, Equatable, Hashable, Sendable {
    /// Compatibility policy for decisions created before automatic app access
    /// existed. These records may inform native UI, but can never authorize an
    /// automatic exact-window grant.
    case promptEachWindow
    /// A user explicitly chose Always Allow App. The policy may authorize a
    /// newly resolved exact window only through the requester-bound lookup API.
    case autoGrantUniqueWindow
}

public struct PersistentAppConsent: Codable, Equatable, Sendable {
    public static let legacyRecordVersion = 1
    public static let currentRecordVersion = 2

    public let recordVersion: Int
    public let policy: PersistentAppConsentPolicy
    public let bundleIdentifier: String
    public let signingIdentity: String
    public let requesterBundleIdentifier: String?
    public let requesterSigningIdentity: String?
    public let capabilities: Set<PublicCapability>
    public let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case recordVersion, policy, bundleIdentifier, signingIdentity
        case requesterBundleIdentifier, requesterSigningIdentity
        case capabilities, updatedAt
    }

    fileprivate init(
        recordVersion: Int,
        policy: PersistentAppConsentPolicy,
        bundleIdentifier: String,
        signingIdentity: String,
        requesterBundleIdentifier: String?,
        requesterSigningIdentity: String?,
        capabilities: Set<PublicCapability>,
        updatedAt: Date
    ) throws {
        try Self.validate(
            recordVersion: recordVersion,
            policy: policy,
            bundleIdentifier: bundleIdentifier,
            signingIdentity: signingIdentity,
            requesterBundleIdentifier: requesterBundleIdentifier,
            requesterSigningIdentity: requesterSigningIdentity,
            capabilities: capabilities
        )
        self.recordVersion = recordVersion
        self.policy = policy
        self.bundleIdentifier = bundleIdentifier
        self.signingIdentity = signingIdentity
        self.requesterBundleIdentifier = requesterBundleIdentifier
        self.requesterSigningIdentity = requesterSigningIdentity
        self.capabilities = capabilities
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .recordVersion)
        let decodedPolicy = try container.decodeIfPresent(PersistentAppConsentPolicy.self, forKey: .policy)

        // The unversioned v1 array is the only legacy shape. Accepting a record
        // with just one discriminator would let truncation or hand-editing
        // accidentally change its authority, so partial version metadata is
        // rejected instead of guessed.
        let version: Int
        let policy: PersistentAppConsentPolicy
        switch (decodedVersion, decodedPolicy) {
        case (nil, nil):
            version = Self.legacyRecordVersion
            policy = .promptEachWindow
        case let (version?, policy?):
            self.recordVersion = version
            self.policy = policy
            self.bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
            self.signingIdentity = try container.decode(String.self, forKey: .signingIdentity)
            self.requesterBundleIdentifier = try container.decodeIfPresent(
                String.self,
                forKey: .requesterBundleIdentifier
            )
            self.requesterSigningIdentity = try container.decodeIfPresent(
                String.self,
                forKey: .requesterSigningIdentity
            )
            self.capabilities = try container.decode(Set<PublicCapability>.self, forKey: .capabilities)
            self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            try Self.validate(
                recordVersion: recordVersion,
                policy: self.policy,
                bundleIdentifier: bundleIdentifier,
                signingIdentity: signingIdentity,
                requesterBundleIdentifier: requesterBundleIdentifier,
                requesterSigningIdentity: requesterSigningIdentity,
                capabilities: capabilities
            )
            return
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Consent records require both recordVersion and policy"
                )
            )
        }

        self.recordVersion = version
        self.policy = policy
        self.bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        self.signingIdentity = try container.decode(String.self, forKey: .signingIdentity)
        self.requesterBundleIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .requesterBundleIdentifier
        )
        self.requesterSigningIdentity = try container.decodeIfPresent(
            String.self,
            forKey: .requesterSigningIdentity
        )
        self.capabilities = try container.decode(Set<PublicCapability>.self, forKey: .capabilities)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        try Self.validate(
            recordVersion: recordVersion,
            policy: self.policy,
            bundleIdentifier: bundleIdentifier,
            signingIdentity: signingIdentity,
            requesterBundleIdentifier: requesterBundleIdentifier,
            requesterSigningIdentity: requesterSigningIdentity,
            capabilities: capabilities
        )
    }

    private static func validate(
        recordVersion: Int,
        policy: PersistentAppConsentPolicy,
        bundleIdentifier: String,
        signingIdentity: String,
        requesterBundleIdentifier: String?,
        requesterSigningIdentity: String?,
        capabilities: Set<PublicCapability>
    ) throws {
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !signingIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !capabilities.isEmpty,
              PublicCapabilityPolicy.isCoherent(capabilities) else {
            throw ConsentStoreError.invalidRecord
        }
        switch (recordVersion, policy) {
        case (Self.legacyRecordVersion, .promptEachWindow):
            guard requesterBundleIdentifier == nil, requesterSigningIdentity == nil else {
                throw ConsentStoreError.invalidRecord
            }
        case (Self.currentRecordVersion, .autoGrantUniqueWindow):
            guard let requesterBundleIdentifier,
                  let requesterSigningIdentity,
                  !requesterBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !requesterSigningIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConsentStoreError.invalidRecord
            }
        default:
            throw ConsentStoreError.invalidRecord
        }
    }
}

public actor PersistentAppConsentStore {
    private struct RecordKey: Hashable {
        let policy: PersistentAppConsentPolicy
        let bundleIdentifier: String
        let signingIdentity: String
        let requesterBundleIdentifier: String?
        let requesterSigningIdentity: String?
    }

    private struct RequesterIdentity {
        let bundleIdentifier: String
        let signingIdentity: String

        init?(peer: PeerIdentity) {
            guard peer.harnessIdentityVerified,
                  let bundleIdentifier = peer.harnessBundleIdentifier,
                  let signingIdentity = peer.harnessSigningIdentity,
                  !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !signingIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            self.bundleIdentifier = bundleIdentifier
            self.signingIdentity = signingIdentity
        }
    }

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
    private var records: [RecordKey: PersistentAppConsent]

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
            let values: [PersistentAppConsent]
            do {
                values = try JSONDecoder.consent.decode([PersistentAppConsent].self, from: data)
            } catch {
                throw ConsentStoreError.invalidRecord
            }
            var decoded: [RecordKey: PersistentAppConsent] = [:]
            for value in values {
                let key = Self.key(value)
                // Duplicate authority records are ambiguous and previously
                // caused Dictionary(uniqueKeysWithValues:) to trap. Treat them
                // as corrupt and keep the host fail-closed.
                guard decoded.updateValue(value, forKey: key) == nil else {
                    throw ConsentStoreError.invalidRecord
                }
            }
            self.records = decoded
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

    /// Compatibility/presentation lookup. This can report that a target app is
    /// remembered, but it is deliberately insufficient to authorize automatic
    /// control because it has no verified requester identity.
    public func allows(window: WindowIdentity, capabilities: Set<PublicCapability>) -> Bool {
        guard Self.validCapabilities(capabilities) else { return false }
        return records.values.contains { record in
            record.bundleIdentifier == window.bundleIdentifier &&
                record.signingIdentity == window.signingIdentity &&
                capabilities.isSubset(of: record.capabilities)
        }
    }

    /// Legacy compatibility API. It records only a prompt-each-window decision
    /// and can never create automatic grant authority. New explicit Always
    /// Allow UI must call recordAutoGrantUniqueWindow instead.
    public func record(window: WindowIdentity, capabilities: Set<PublicCapability>, now: Date = Date()) throws {
        guard Self.validCapabilities(capabilities) else { throw ConsentStoreError.invalidCapabilities }
        let key = Self.legacyKey(window: window)
        let combined = records[key]?.capabilities.union(capabilities) ?? capabilities
        var updated = records
        updated[key] = try PersistentAppConsent(
            recordVersion: PersistentAppConsent.legacyRecordVersion,
            policy: .promptEachWindow,
            bundleIdentifier: window.bundleIdentifier,
            signingIdentity: window.signingIdentity,
            requesterBundleIdentifier: nil,
            requesterSigningIdentity: nil,
            capabilities: combined,
            updatedAt: now
        )
        try persist(updated)
        records = updated
    }

    /// Persists an explicit Always Allow App choice. The requester must be a
    /// verified GUI harness; PID and process generation are intentionally not
    /// persisted, while its bundle and designated-requirement digest are.
    public func recordAutoGrantUniqueWindow(
        requester: PeerIdentity,
        window: WindowIdentity,
        capabilities: Set<PublicCapability>,
        now: Date = Date()
    ) throws {
        guard let requester = RequesterIdentity(peer: requester) else {
            throw ConsentStoreError.unverifiedRequester
        }
        guard Self.validCapabilities(capabilities) else {
            throw ConsentStoreError.invalidCapabilities
        }
        let key = Self.autoKey(requester: requester, window: window)
        let combined = records[key]?.capabilities.union(capabilities) ?? capabilities
        var updated = records
        updated[key] = try PersistentAppConsent(
            recordVersion: PersistentAppConsent.currentRecordVersion,
            policy: .autoGrantUniqueWindow,
            bundleIdentifier: window.bundleIdentifier,
            signingIdentity: window.signingIdentity,
            requesterBundleIdentifier: requester.bundleIdentifier,
            requesterSigningIdentity: requester.signingIdentity,
            capabilities: combined,
            updatedAt: now
        )
        try persist(updated)
        records = updated
    }

    /// Returns true only for an explicit v2 Always Allow policy whose requester
    /// harness, target app signing identity, and capability ceiling all match.
    /// Candidate uniqueness and fresh exact-window binding remain HostController
    /// responsibilities and are not implied by this result.
    public func allowsAutoGrantUniqueWindow(
        requester: PeerIdentity,
        window: WindowIdentity,
        capabilities: Set<PublicCapability>
    ) -> Bool {
        guard let requester = RequesterIdentity(peer: requester),
              Self.validCapabilities(capabilities),
              let record = records[Self.autoKey(requester: requester, window: window)],
              record.recordVersion == PersistentAppConsent.currentRecordVersion,
              record.policy == .autoGrantUniqueWindow else {
            return false
        }
        return capabilities.isSubset(of: record.capabilities)
    }

    /// Removes exactly one settings row/policy. This is the preferred revoke
    /// path once requester-bound policies exist because multiple harnesses may
    /// independently allow the same signed target application.
    @discardableResult
    public func revoke(_ record: PersistentAppConsent) throws -> Bool {
        var updated = records
        guard updated.removeValue(forKey: Self.key(record)) != nil else { return false }
        try persist(updated)
        records = updated
        return true
    }

    /// Compatibility revoke for the original target-only settings UI. It
    /// removes the legacy row and every requester-bound policy for that signed
    /// target. New UI should prefer revoke(_:) for one-row removal.
    public func revoke(bundleIdentifier: String, signingIdentity: String) throws {
        var updated = records
        updated = updated.filter { key, _ in
            key.bundleIdentifier != bundleIdentifier || key.signingIdentity != signingIdentity
        }
        try persist(updated)
        records = updated
    }

    public func revokeAll() throws {
        try persist([:])
        records.removeAll()
    }

    public func all() -> [PersistentAppConsent] {
        Self.sorted(records.values)
    }

    private func persist(_ updated: [RecordKey: PersistentAppConsent]) throws {
        let data = try JSONEncoder.consent.encode(Self.sorted(updated.values))
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

    private static func key(_ record: PersistentAppConsent) -> RecordKey {
        RecordKey(
            policy: record.policy,
            bundleIdentifier: record.bundleIdentifier,
            signingIdentity: record.signingIdentity,
            requesterBundleIdentifier: record.requesterBundleIdentifier,
            requesterSigningIdentity: record.requesterSigningIdentity
        )
    }

    private static func legacyKey(window: WindowIdentity) -> RecordKey {
        RecordKey(
            policy: .promptEachWindow,
            bundleIdentifier: window.bundleIdentifier,
            signingIdentity: window.signingIdentity,
            requesterBundleIdentifier: nil,
            requesterSigningIdentity: nil
        )
    }

    private static func autoKey(requester: RequesterIdentity, window: WindowIdentity) -> RecordKey {
        RecordKey(
            policy: .autoGrantUniqueWindow,
            bundleIdentifier: window.bundleIdentifier,
            signingIdentity: window.signingIdentity,
            requesterBundleIdentifier: requester.bundleIdentifier,
            requesterSigningIdentity: requester.signingIdentity
        )
    }

    private static func validCapabilities(_ capabilities: Set<PublicCapability>) -> Bool {
        !capabilities.isEmpty && PublicCapabilityPolicy.isCoherent(capabilities)
    }

    private static func sorted<S: Sequence>(_ values: S) -> [PersistentAppConsent]
    where S.Element == PersistentAppConsent {
        values.sorted { left, right in
            let leftKey = [
                left.bundleIdentifier,
                left.signingIdentity,
                left.policy.rawValue,
                left.requesterBundleIdentifier ?? "",
                left.requesterSigningIdentity ?? "",
            ]
            let rightKey = [
                right.bundleIdentifier,
                right.signingIdentity,
                right.policy.rawValue,
                right.requesterBundleIdentifier ?? "",
                right.requesterSigningIdentity ?? "",
            ]
            return leftKey.lexicographicallyPrecedes(rightKey)
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
    case invalidRecord
    case invalidCapabilities
    case unverifiedRequester
}
