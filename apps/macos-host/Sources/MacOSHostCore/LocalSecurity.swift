import Darwin
import CryptoKit
import Foundation
import Security

public enum CanonicalRuntime {
    public static let socketEnvironmentKey = "COMPUTER_USE_MCP_SOCKET_PATH"
    public static let bridgeBundleIdentifier = "com.jmeguilos.computer-use-mcp.bridge"
    public static let hostBundleIdentifier = "com.jmeguilos.computer-use-mcp.host"
    public static let hostExecutableName = "ComputerUseMCPHost"

    public static func directory(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("ComputerUseMCP/runtime", isDirectory: true)
    }
}

/// Opens sensitive local files without following links, validates the opened
/// inode, and reads from that same descriptor with a hard size bound. Keeping
/// validation and I/O on one descriptor removes the lstat-then-open race.
enum SecureFileIO {
    static func readIfExists(
        path: String,
        requiredMode: mode_t,
        maximumBytes: Int,
        expectedUID: uid_t = getuid()
    ) throws -> Data? {
        guard maximumBytes > 0 else { throw LocalSecurityError.fileTooLarge }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw LocalSecurityError.symbolicLinkRejected }
            throw LocalSecurityError.metadataUnavailable
        }
        defer { close(descriptor) }

        let before = try validatedStatus(
            descriptor: descriptor,
            requiredMode: requiredMode,
            expectedUID: expectedUID
        )
        guard before.st_size >= 0, before.st_size <= off_t(maximumBytes) else {
            throw LocalSecurityError.fileTooLarge
        }

        var data = Data()
        data.reserveCapacity(min(Int(before.st_size), maximumBytes))
        var buffer = [UInt8](repeating: 0, count: min(4_096, maximumBytes + 1))
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            let requested = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw LocalSecurityError.fileReadFailed
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumBytes else { throw LocalSecurityError.fileTooLarge }

        let after = try validatedStatus(
            descriptor: descriptor,
            requiredMode: requiredMode,
            expectedUID: expectedUID
        )
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
            throw LocalSecurityError.metadataUnavailable
        }
        return data
    }

    static func validateDescriptor(
        _ descriptor: Int32,
        requiredMode: mode_t,
        expectedUID: uid_t = getuid()
    ) throws {
        _ = try validatedStatus(
            descriptor: descriptor,
            requiredMode: requiredMode,
            expectedUID: expectedUID
        )
    }

    private static func validatedStatus(
        descriptor: Int32,
        requiredMode: mode_t,
        expectedUID: uid_t
    ) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw LocalSecurityError.metadataUnavailable }
        guard status.st_uid == expectedUID else { throw LocalSecurityError.ownerMismatch }
        guard status.st_mode & S_IFMT == S_IFREG else { throw LocalSecurityError.invalidFileType }
        guard status.st_mode & 0o777 == requiredMode else { throw LocalSecurityError.permissionMismatch }
        return status
    }
}

public enum DevelopmentModeAuthorization {
    public static let markerFileName = "source-development-mode"
    public static let markerContents = "ComputerUseMCP source development v1\n"

    public static func validate(configuration: SocketConfiguration) -> Bool {
        let path = configuration.runtimeDirectory.appendingPathComponent(markerFileName).path
        guard let data = try? SecureFileIO.readIfExists(
            path: path,
            requiredMode: S_IRUSR | S_IWUSR,
            maximumBytes: 256
        ),
              String(data: data, encoding: .utf8) == markerContents else { return false }
        return true
    }
}

public enum CurrentCodeSigningIdentity: Equatable, Sendable {
    case release(teamIdentifier: String)
    case adHoc
}

public enum PeerVerifierMode: Equatable, Sendable {
    case release(teamIdentifier: String)
    case sourceDevelopment
    case denied
}

/// A Developer ID identity always selects the release verifier. An ad-hoc
/// source build may use the development verifier only while the setup-created,
/// private authorization marker remains valid. The persistent marker is needed
/// because LaunchServices does not preserve command-line arguments when macOS
/// performs a permission-related Quit & Reopen.
public enum PeerVerifierPolicy {
    public static func select(
        signingIdentity: CurrentCodeSigningIdentity,
        sourceAuthorizationValid: Bool
    ) -> PeerVerifierMode {
        switch signingIdentity {
        case let .release(teamIdentifier):
            return .release(teamIdentifier: teamIdentifier)
        case .adHoc:
            return sourceAuthorizationValid ? .sourceDevelopment : .denied
        }
    }
}

public struct SocketConfiguration: Equatable, Sendable {
    public let runtimeDirectory: URL
    public let socketURL: URL
    public let authenticationTokenURL: URL

    public init(runtimeDirectory: URL, socketURL: URL, authenticationTokenURL: URL) {
        self.runtimeDirectory = runtimeDirectory
        self.socketURL = socketURL
        self.authenticationTokenURL = authenticationTokenURL
    }

    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> SocketConfiguration {
        let socketURL: URL
        if let override = environment[CanonicalRuntime.socketEnvironmentKey], !override.isEmpty {
            guard override.hasPrefix("/") else { throw LocalSecurityError.socketPathMustBeAbsolute }
            socketURL = URL(fileURLWithPath: override).standardizedFileURL
        } else {
            socketURL = try CanonicalRuntime.directory(fileManager: fileManager)
                .appendingPathComponent("host.sock", isDirectory: false)
        }
        let directory = socketURL.deletingLastPathComponent()
        return SocketConfiguration(
            runtimeDirectory: directory,
            socketURL: socketURL,
            authenticationTokenURL: directory.appendingPathComponent("auth.token")
        )
    }
}

public enum SecureTokenGenerator {
    public static func generate(byteCount: Int = 32) throws -> String {
        guard byteCount >= 32 else { throw LocalSecurityError.randomGenerationFailed }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalSecurityError.randomGenerationFailed
        }
        return Data(bytes).base64EncodedString()
    }
}

public struct RuntimeCredentialStore: Sendable {
    public let configuration: SocketConfiguration

    public init(configuration: SocketConfiguration) { self.configuration = configuration }

    public func prepare() throws -> String {
        try ensurePrivateDirectory(configuration.runtimeDirectory)
        let path = configuration.authenticationTokenURL.path
        if let data = try SecureFileIO.readIfExists(
            path: path,
            requiredMode: S_IRUSR | S_IWUSR,
            maximumBytes: 4_096
        ) {
            guard let contents = String(data: data, encoding: .utf8) else {
                throw LocalSecurityError.invalidStoredToken
            }
            let token = contents
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.count >= 43 else { throw LocalSecurityError.invalidStoredToken }
            return token
        }
        let token = try SecureTokenGenerator.generate()
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LocalSecurityError.credentialCreationFailed }
        defer { close(descriptor) }
        let data = Data(token.utf8)
        let wrote = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard wrote == data.count, fsync(descriptor) == 0 else { throw LocalSecurityError.credentialCreationFailed }
        try SecureFileIO.validateDescriptor(descriptor, requiredMode: S_IRUSR | S_IWUSR)
        return token
    }

    /// Bridge-side read path. It never creates or repairs credentials because
    /// only the host owns runtime initialization.
    public func loadExisting() throws -> String {
        let directory = configuration.runtimeDirectory.path
        let path = configuration.authenticationTokenURL.path
        try rejectSymbolicLink(directory)
        try validateOwnerAndMode(path: directory, requiredMode: S_IRWXU, directory: true)
        guard let data = try SecureFileIO.readIfExists(
            path: path,
            requiredMode: S_IRUSR | S_IWUSR,
            maximumBytes: 4_096
        ), let contents = String(data: data, encoding: .utf8) else {
            throw LocalSecurityError.invalidStoredToken
        }
        let token = contents
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 43 else { throw LocalSecurityError.invalidStoredToken }
        return token
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            // An override may name an existing shared directory such as /tmp.
            // Never "repair" it: doing so could remove access for every other
            // user and process. Existing directories must already satisfy the
            // host's owner/type/mode contract exactly.
            try rejectSymbolicLink(url.path)
            try validateOwnerAndMode(path: url.path, requiredMode: S_IRWXU, directory: true)
            return
        }
        guard errno == ENOENT else { throw LocalSecurityError.metadataUnavailable }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int(S_IRWXU))]
        )
        try rejectSymbolicLink(url.path)
        // FileManager honors umask. Tighten only the dedicated leaf that this
        // call just created, never an existing parent supplied by the caller.
        guard chmod(url.path, S_IRWXU) == 0 else { throw LocalSecurityError.permissionUpdateFailed }
        try validateOwnerAndMode(path: url.path, requiredMode: S_IRWXU, directory: true)
    }

    private func rejectSymbolicLink(_ path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else { throw LocalSecurityError.metadataUnavailable }
        guard (status.st_mode & S_IFMT) != S_IFLNK else { throw LocalSecurityError.symbolicLinkRejected }
    }

    private func validateOwnerAndMode(path: String, requiredMode: mode_t, directory: Bool) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else { throw LocalSecurityError.metadataUnavailable }
        guard status.st_uid == getuid() else { throw LocalSecurityError.ownerMismatch }
        let kind = status.st_mode & S_IFMT
        guard kind == (directory ? S_IFDIR : S_IFREG) else { throw LocalSecurityError.invalidFileType }
        guard status.st_mode & 0o777 == requiredMode else { throw LocalSecurityError.permissionMismatch }
    }
}

public struct SocketPeerCredentials: Equatable, Sendable {
    public let uid: UInt32
    public let processID: Int32
    public let auditToken: Data

    public init(uid: UInt32, processID: Int32, auditToken: Data) {
        self.uid = uid
        self.processID = processID
        self.auditToken = auditToken
    }
}

public protocol SocketPeerInspecting: Sendable {
    func credentials(socket: Int32) throws -> SocketPeerCredentials
}

public struct DarwinSocketPeerInspector: SocketPeerInspecting {
    public init() {}

    public func credentials(socket: Int32) throws -> SocketPeerCredentials {
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(socket, &uid, &gid) == 0 else { throw LocalSecurityError.peerCredentialUnavailable }

        var processID = pid_t()
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &processID, &pidLength) == 0,
              pidLength == MemoryLayout<pid_t>.size else {
            throw LocalSecurityError.peerCredentialUnavailable
        }

        var auditToken = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &auditToken, &tokenLength) == 0,
              tokenLength == MemoryLayout<audit_token_t>.size else {
            throw LocalSecurityError.auditTokenUnavailable
        }
        let tokenPID = audit_token_to_pid(auditToken)
        let tokenUID = audit_token_to_euid(auditToken)
        guard tokenPID == processID, tokenUID == uid else { throw LocalSecurityError.auditTokenMismatch }
        let data = withUnsafeBytes(of: auditToken) { Data($0) }
        return SocketPeerCredentials(uid: UInt32(uid), processID: Int32(processID), auditToken: data)
    }
}

public protocol PeerCodeVerifying: Sendable {
    func verify(_ peer: SocketPeerCredentials) throws
}

/// Release policy: the peer must be the signed bridge identifier and match the
/// configured Team ID. An unsigned/ad-hoc peer cannot satisfy this requirement.
public struct ReleasePeerCodeVerifier: PeerCodeVerifying {
    public let teamIdentifier: String
    public let bundleIdentifier: String

    public init(
        teamIdentifier: String,
        bundleIdentifier: String = CanonicalRuntime.bridgeBundleIdentifier
    ) throws {
        guard !teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalSecurityError.missingTeamIdentifier
        }
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !bundleIdentifier.contains("\"") else {
            throw LocalSecurityError.invalidSigningRequirement
        }
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
    }

    public func verify(_ peer: SocketPeerCredentials) throws {
        guard peer.auditToken.count == MemoryLayout<audit_token_t>.size else {
            throw LocalSecurityError.auditTokenUnavailable
        }
        let attributes = [kSecGuestAttributeAudit as String: peer.auditToken as CFData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest else { throw LocalSecurityError.signatureUnavailable }
        let escapedTeam = teamIdentifier.replacingOccurrences(of: "\"", with: "")
        let requirementText = "identifier \"\(bundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(escapedTeam)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw LocalSecurityError.invalidSigningRequirement }
        guard SecCodeCheckValidity(guest, [], requirement) == errSecSuccess else {
            throw LocalSecurityError.signatureRejected
        }
    }
}

/// Pins a socket peer to the exact signed executable shipped beside the
/// caller. This protects source-development builds from a replacement socket
/// server without pretending that a user-writable source app is a hardened
/// system boundary.
public struct PinnedExecutablePeerCodeVerifier: PeerCodeVerifying {
    public let executableURL: URL

    public init(executableURL: URL) throws {
        let resolved = executableURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.isFileURL, resolved.path.hasPrefix("/") else {
            throw LocalSecurityError.invalidSigningRequirement
        }
        self.executableURL = resolved
    }

    public func verify(_ peer: SocketPeerCredentials) throws {
        guard peer.auditToken.count == MemoryLayout<audit_token_t>.size else {
            throw LocalSecurityError.auditTokenUnavailable
        }
        let attributes = [kSecGuestAttributeAudit as String: peer.auditToken as CFData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest else { throw LocalSecurityError.signatureUnavailable }

        var expectedStatic: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &expectedStatic) == errSecSuccess,
              let expectedStatic else { throw LocalSecurityError.signatureUnavailable }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(expectedStatic, [], &requirement) == errSecSuccess,
              let requirement else { throw LocalSecurityError.invalidSigningRequirement }
        guard SecCodeCheckValidity(
            guest,
            [],
            requirement
        ) == errSecSuccess else { throw LocalSecurityError.signatureRejected }

        // proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN, but
        // the macro is not imported by the Swift overlay.
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let pathLength = proc_pidpath(peer.processID, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { throw LocalSecurityError.signatureUnavailable }
        let resolvedGuest = URL(fileURLWithPath: String(cString: pathBuffer))
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedGuest == executableURL else { throw LocalSecurityError.signatureRejected }
    }
}

public struct CompositePeerCodeVerifier: PeerCodeVerifying {
    public let verifiers: [any PeerCodeVerifying]

    public init(_ verifiers: [any PeerCodeVerifying]) {
        self.verifiers = verifiers
    }

    public func verify(_ peer: SocketPeerCredentials) throws {
        for verifier in verifiers { try verifier.verify(peer) }
    }
}

public enum BridgeHostPeerVerifierFactory {
    public static func hostExecutableURL(forBridgeExecutable bridgeExecutableURL: URL) -> URL {
        let bridge = bridgeExecutableURL.resolvingSymlinksInPath().standardizedFileURL
        let directory = bridge.deletingLastPathComponent()
        if directory.lastPathComponent == "Helpers",
           directory.deletingLastPathComponent().lastPathComponent == "Contents" {
            return directory
                .deletingLastPathComponent()
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent(CanonicalRuntime.hostExecutableName, isDirectory: false)
        }
        return directory.appendingPathComponent(CanonicalRuntime.hostExecutableName, isDirectory: false)
    }

    public static func make(
        configuration: SocketConfiguration,
        bridgeExecutableURL: URL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
    ) throws -> any PeerCodeVerifying {
        let hostURL = hostExecutableURL(forBridgeExecutable: bridgeExecutableURL)
        let pinned = try PinnedExecutablePeerCodeVerifier(executableURL: hostURL)
        switch PeerVerifierPolicy.select(
            signingIdentity: try CurrentCodeIdentity.signingIdentity(),
            sourceAuthorizationValid: DevelopmentModeAuthorization.validate(configuration: configuration)
        ) {
        case let .release(teamIdentifier):
            return CompositePeerCodeVerifier([
                try ReleasePeerCodeVerifier(
                    teamIdentifier: teamIdentifier,
                    bundleIdentifier: CanonicalRuntime.hostBundleIdentifier
                ),
                pinned,
            ])
        case .sourceDevelopment:
            return pinned
        case .denied:
            throw LocalSecurityError.developmentModeDisabled
        }
    }
}

public enum CurrentCodeIdentity {
    // `kSecCodeSignatureAdhoc` is declared as 0x0002 in Security/CSCommon.h but
    // is not imported into Swift by current macOS SDK overlays.
    static let adHocSignatureFlag: UInt32 = 0x0002

    public static func signingIdentity() throws -> CurrentCodeSigningIdentity {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw LocalSecurityError.signatureUnavailable
        }
        guard SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess else {
            throw LocalSecurityError.signatureRejected
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw LocalSecurityError.signatureUnavailable
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let flags = dictionary[kSecCodeInfoFlags as String] as? NSNumber else {
            throw LocalSecurityError.signatureUnavailable
        }
        let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return try classify(
            signingFlags: flags.uint32Value,
            teamIdentifier: teamIdentifier
        )
    }

    static func classify(
        signingFlags: UInt32,
        teamIdentifier: String?
    ) throws -> CurrentCodeSigningIdentity {
        let isAdHoc = signingFlags & adHocSignatureFlag != 0
        let normalizedTeam = teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAdHoc {
            guard normalizedTeam?.isEmpty != false else {
                throw LocalSecurityError.signatureRejected
            }
            return .adHoc
        }
        guard let normalizedTeam, !normalizedTeam.isEmpty else {
            throw LocalSecurityError.missingTeamIdentifier
        }
        return .release(teamIdentifier: normalizedTeam)
    }
}

public enum ProcessCodeIdentity {
    public static func designatedRequirementDigest(processID: Int32) -> String? {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processID)] as CFDictionary
        var dynamicCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &dynamicCode) == errSecSuccess,
              let dynamicCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var data: CFData?
        guard SecRequirementCopyData(requirement, [], &data) == errSecSuccess,
              let data else { return nil }
        return SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
    }
}

/// This verifier exists only for explicit source-build development. It still
/// requires same-user, kernel-derived PID and an audit token; it skips signing.
public struct ExplicitDevelopmentPeerCodeVerifier: PeerCodeVerifying {
    public let explicitlyEnabled: Bool
    public let expectedUID: UInt32

    public init(explicitlyEnabled: Bool, expectedUID: UInt32 = UInt32(getuid())) {
        self.explicitlyEnabled = explicitlyEnabled
        self.expectedUID = expectedUID
    }

    public func verify(_ peer: SocketPeerCredentials) throws {
        guard explicitlyEnabled else { throw LocalSecurityError.developmentModeDisabled }
        guard peer.uid == expectedUID else { throw LocalSecurityError.peerUIDMismatch }
        guard peer.processID > 1, !peer.auditToken.isEmpty else { throw LocalSecurityError.auditTokenUnavailable }
    }
}

public actor HandshakeReplayGuard {
    private var expirations: [String: Date] = [:]
    private let lifetime: TimeInterval

    public init(lifetime: TimeInterval = 900) { self.lifetime = lifetime }

    public func consume(nonce: String, now: Date = Date()) throws {
        expirations = expirations.filter { $0.value > now }
        guard nonce.count >= 22, expirations[nonce] == nil else { throw LocalSecurityError.replayedHandshake }
        expirations[nonce] = now.addingTimeInterval(lifetime)
    }
}

public enum LocalSecurityError: String, Error, Equatable, Sendable {
    case socketPathMustBeAbsolute
    case randomGenerationFailed
    case credentialCreationFailed
    case invalidStoredToken
    case permissionUpdateFailed
    case metadataUnavailable
    case symbolicLinkRejected
    case ownerMismatch
    case invalidFileType
    case permissionMismatch
    case fileTooLarge
    case fileReadFailed
    case peerCredentialUnavailable
    case auditTokenUnavailable
    case auditTokenMismatch
    case missingTeamIdentifier
    case signatureUnavailable
    case invalidSigningRequirement
    case signatureRejected
    case developmentModeDisabled
    case peerUIDMismatch
    case replayedHandshake
}

func secureStringsEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
    for index in 0..<max(a.count, b.count) {
        difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
    }
    return difference == 0
}
