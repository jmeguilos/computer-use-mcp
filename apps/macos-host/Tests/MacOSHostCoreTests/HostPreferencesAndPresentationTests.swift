import Darwin
import Foundation
import Testing
@testable import MacOSHostCore

private enum HostPreferencesFixtureError: Error { case unexpected }

private func preferencesTemporaryDirectory(mode: mode_t = S_IRWXU) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("computer-use-mcp-preferences-tests-\(UUID().uuidString)", isDirectory: true)
    guard mkdir(url.path, mode) == 0, chmod(url.path, mode) == 0 else {
        throw HostPreferencesFixtureError.unexpected
    }
    return url
}

private func preferencesFileMode(_ url: URL) throws -> mode_t {
    var status = stat()
    guard lstat(url.path, &status) == 0 else { throw HostPreferencesFixtureError.unexpected }
    return status.st_mode & 0o777
}

private func writePreferencesFixture(_ text: String, to url: URL, mode: mode_t = 0o600) throws {
    guard FileManager.default.createFile(
        atPath: url.path,
        contents: Data(text.utf8),
        attributes: [.posixPermissions: NSNumber(value: Int(mode))]
    ), chmod(url.path, mode) == 0 else {
        throw HostPreferencesFixtureError.unexpected
    }
}

@Suite("Host preferences and computer-control presentation", .serialized)
struct HostPreferencesAndPresentationTests {
    @Test func missingPreferencesCreateSecureFailClosedDefaults() async throws {
        let root = try preferencesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("preferences", isDirectory: true)
        let url = parent.appendingPathComponent("host.json")

        let store = try PersistentHostPreferencesStore(url: url)
        #expect(await store.snapshot() == .defaults)
        #expect((await store.snapshot()).schemaVersion == HostPreferences.currentSchemaVersion)
        #expect((await store.snapshot()).onboardingRevision == 0)
        #expect(!(await store.snapshot()).anyAppControlEnabled)
        #expect(try preferencesFileMode(parent) == 0o700)
        #expect(try preferencesFileMode(url) == 0o600)
    }

    @Test func preferencesPersistOnlyAfterValidatedAtomicWrites() async throws {
        let root = try preferencesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences/host.json")
        let store = try PersistentHostPreferencesStore(url: url)

        try await store.setAnyAppControlEnabled(true)
        try await store.markCurrentOnboardingCompleted()
        let expected = HostPreferences(
            onboardingRevision: HostPreferences.currentOnboardingRevision,
            anyAppControlEnabled: true
        )
        #expect(await store.snapshot() == expected)
        #expect(await (try PersistentHostPreferencesStore(url: url)).snapshot() == expected)
        #expect(try preferencesFileMode(url) == 0o600)
    }

    @Test func runtimeDisableLatchFailsClosedWithoutClaimingPersistence() async throws {
        let root = try preferencesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences/host.json")
        let store = try PersistentHostPreferencesStore(url: url)
        try await store.setAnyAppControlEnabled(true)

        await store.forceDisableForCurrentProcess()
        #expect(!(await store.snapshot()).anyAppControlEnabled)
        #expect((await (try PersistentHostPreferencesStore(url: url)).snapshot()).anyAppControlEnabled)
    }

    @Test func unsafeDirectoryAndFileModesFailClosed() throws {
        let root = try preferencesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let unsafeParent = root.appendingPathComponent("unsafe-parent", isDirectory: true)
        guard mkdir(unsafeParent.path, 0o755) == 0, chmod(unsafeParent.path, 0o755) == 0 else {
            throw HostPreferencesFixtureError.unexpected
        }
        #expect(throws: HostPreferencesStoreError.unsafeDirectory) {
            try PersistentHostPreferencesStore(url: unsafeParent.appendingPathComponent("host.json"))
        }

        let safeParent = root.appendingPathComponent("safe-parent", isDirectory: true)
        guard mkdir(safeParent.path, 0o700) == 0, chmod(safeParent.path, 0o700) == 0 else {
            throw HostPreferencesFixtureError.unexpected
        }
        let looseFile = safeParent.appendingPathComponent("host.json")
        try writePreferencesFixture(
            #"{"schemaVersion":1,"onboardingRevision":0,"anyAppControlEnabled":false}"#,
            to: looseFile,
            mode: 0o644
        )
        #expect(throws: HostPreferencesStoreError.unsafeFile) {
            try PersistentHostPreferencesStore(url: looseFile)
        }
    }

    @Test func symbolicLinkAndInvalidContentsFailClosed() throws {
        let root = try preferencesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("preferences", isDirectory: true)
        guard mkdir(parent.path, 0o700) == 0, chmod(parent.path, 0o700) == 0 else {
            throw HostPreferencesFixtureError.unexpected
        }
        let target = root.appendingPathComponent("target.json")
        let valid = #"{"schemaVersion":1,"onboardingRevision":0,"anyAppControlEnabled":false}"#
        try writePreferencesFixture(valid, to: target)
        let linked = parent.appendingPathComponent("host.json")
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: target.path)
        #expect(throws: HostPreferencesStoreError.unsafeFile) {
            try PersistentHostPreferencesStore(url: linked)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == valid)

        try FileManager.default.removeItem(at: linked)
        try writePreferencesFixture("not-json", to: linked)
        #expect(throws: HostPreferencesStoreError.invalidContents) {
            try PersistentHostPreferencesStore(url: linked)
        }

        try FileManager.default.removeItem(at: linked)
        try writePreferencesFixture(
            #"{"schemaVersion":2,"onboardingRevision":0,"anyAppControlEnabled":false}"#,
            to: linked
        )
        #expect(throws: HostPreferencesStoreError.unsupportedSchemaVersion) {
            try PersistentHostPreferencesStore(url: linked)
        }
    }

    @Test func presentationAlwaysHasExactlyTwoUserFacingPermissionRows() {
        let ready = PermissionSnapshot(
            screenCapture: .granted,
            accessibility: .granted,
            eventPosting: .granted,
            eventListening: .denied
        )
        let presentation = ComputerControlPresentation(
            permissions: ready,
            anyAppControlEnabled: true
        )
        #expect(presentation.permissionRows.map(\.kind) == [.screenRecording, .accessibility])
        #expect(presentation.permissionRows.map(\.status) == [.ready, .ready])
        #expect(presentation.availability == .ready)

        let listeningGranted = PermissionSnapshot(
            screenCapture: .granted,
            accessibility: .granted,
            eventPosting: .granted,
            eventListening: .granted
        )
        #expect(ComputerControlPresentation(
            permissions: listeningGranted,
            anyAppControlEnabled: true
        ) == presentation)
    }

    @Test func accessibilityPresentationIncludesPostingAndGlobalDisableWins() {
        let missingPosting = PermissionSnapshot(
            screenCapture: .granted,
            accessibility: .granted,
            eventPosting: .denied,
            eventListening: .granted
        )
        let needsAccess = ComputerControlPresentation(
            permissions: missingPosting,
            anyAppControlEnabled: true
        )
        #expect(needsAccess.permissionRows == [
            ComputerControlPermissionRow(kind: .screenRecording, status: .ready),
            ComputerControlPermissionRow(kind: .accessibility, status: .needsAccess),
        ])
        #expect(needsAccess.availability == .needsSystemAccess)

        let disabled = ComputerControlPresentation(
            permissions: missingPosting,
            anyAppControlEnabled: false
        )
        #expect(disabled.permissionRows == needsAccess.permissionRows)
        #expect(disabled.availability == .disabled)
    }
}

@Suite("Persistent app consent", .serialized)
struct PersistentAppConsentTests {
    private func identity() throws -> WindowIdentity {
        try WindowIdentity(
            windowID: 42,
            processID: 4242,
            bundleIdentifier: "com.example.fixture",
            ownerName: "Fixture",
            signingIdentity: "designated-requirement-digest",
            processStartTimeUnixMs: 1_700_000_000_000
        )
    }

    @Test func failedRecordPersistenceDoesNotCreateInMemoryConsent() async throws {
        let root = try preferencesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("consent/apps.json")
        let store = try PersistentAppConsentStore(url: url)
        let parent = url.deletingLastPathComponent()
        guard chmod(parent.path, 0o500) == 0 else {
            throw HostPreferencesFixtureError.unexpected
        }
        defer { _ = chmod(parent.path, 0o700) }

        do {
            try await store.record(window: identity(), capabilities: [.observe])
            Issue.record("failed consent persistence mutated the in-memory store")
        } catch {
            #expect(error as? ConsentStoreError == .unsafeDirectory)
        }
        #expect((await store.all()).isEmpty)
    }

    @Test func failedRevokePersistenceKeepsExistingConsentInMemoryAndOnDisk() async throws {
        let root = try preferencesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("consent/apps.json")
        let store = try PersistentAppConsentStore(url: url)
        let window = try identity()
        try await store.record(window: window, capabilities: [.observe, .interact])
        guard chmod(url.path, 0o644) == 0 else {
            throw HostPreferencesFixtureError.unexpected
        }

        do {
            try await store.revoke(
                bundleIdentifier: window.bundleIdentifier,
                signingIdentity: window.signingIdentity
            )
            Issue.record("failed consent persistence removed live authority policy")
        } catch {
            #expect(error as? ConsentStoreError == .unsafeFile)
        }
        #expect((await store.all()).count == 1)

        guard chmod(url.path, 0o600) == 0 else {
            throw HostPreferencesFixtureError.unexpected
        }
        let persisted = await (try PersistentAppConsentStore(url: url)).all()
        let inMemory = await store.all()
        #expect(persisted.count == 1)
        #expect(inMemory.count == 1)
        guard let persistedRecord = persisted.first, let inMemoryRecord = inMemory.first else {
            Issue.record("consent disappeared after a failed revoke")
            return
        }
        #expect(persistedRecord.bundleIdentifier == inMemoryRecord.bundleIdentifier)
        #expect(persistedRecord.signingIdentity == inMemoryRecord.signingIdentity)
        #expect(persistedRecord.capabilities == inMemoryRecord.capabilities)
        // ISO-8601 persistence is second-granular while the live record keeps
        // Date's subsecond precision.
        #expect(abs(persistedRecord.updatedAt.timeIntervalSince(inMemoryRecord.updatedAt)) < 1)
    }
}
