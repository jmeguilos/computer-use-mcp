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
    private func identity(
        windowID: UInt32 = 42,
        bundleIdentifier: String = "com.example.fixture",
        signingIdentity: String = "designated-requirement-digest"
    ) throws -> WindowIdentity {
        try WindowIdentity(
            windowID: windowID,
            processID: 4242,
            bundleIdentifier: bundleIdentifier,
            ownerName: "Fixture",
            signingIdentity: signingIdentity,
            processStartTimeUnixMs: 1_700_000_000_000
        )
    }

    private func requester(
        bundleIdentifier: String = "com.example.cursor",
        signingIdentity: String = "cursor-designated-requirement-digest",
        verified: Bool = true
    ) -> PeerIdentity {
        PeerIdentity(
            uid: UInt32(getuid()),
            processID: 7_777,
            name: "Fixture harness",
            instanceID: "fixture-harness",
            harnessProcessID: 8_888,
            harnessBundleIdentifier: bundleIdentifier,
            harnessSigningIdentity: signingIdentity,
            harnessProcessStartTimeUnixMs: 1_700_000_100_000,
            harnessIdentityVerified: verified
        )
    }

    private func writeConsentFixture(_ text: String, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int(S_IRWXU))]
        )
        guard chmod(parent.path, S_IRWXU) == 0 else {
            throw HostPreferencesFixtureError.unexpected
        }
        try writePreferencesFixture(text, to: url)
    }

    @Test func unversionedConsentMigratesToPromptOnlyWithoutAutomaticAuthority() async throws {
        let root = try preferencesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("consent/apps.json")
        try writeConsentFixture(
            """
            [{"bundleIdentifier":"com.example.fixture","capabilities":["observe","interact"],"signingIdentity":"designated-requirement-digest","updatedAt":"2026-08-30T00:00:00Z"}]
            """,
            to: url
        )

        let store = try PersistentAppConsentStore(url: url)
        let window = try identity()
        let records = await store.all()
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.recordVersion == PersistentAppConsent.legacyRecordVersion)
        #expect(record.policy == .promptEachWindow)
        #expect(record.requesterBundleIdentifier == nil)
        #expect(record.requesterSigningIdentity == nil)
        #expect(await store.allows(window: window, capabilities: [.observe]))
        #expect(!(await store.allowsAutoGrantUniqueWindow(
            requester: requester(),
            window: window,
            capabilities: [.observe]
        )))
    }

    @Test func automaticConsentBindsRequesterTargetSigningAndCapabilityCeiling() async throws {
        let root = try preferencesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("consent/apps.json")
        let store = try PersistentAppConsentStore(url: url)
        let approvedRequester = requester()
        let approvedWindow = try identity()
        let recreatedWindow = try identity(windowID: 43)
        let replacementSignedWindow = try identity(
            signingIdentity: "replacement-target-signing-digest"
        )

        try await store.recordAutoGrantUniqueWindow(
            requester: approvedRequester,
            window: approvedWindow,
            capabilities: [.observe, .interact],
            now: Date(timeIntervalSince1970: 1_777_776_000)
        )

        // A recreated exact window from the same signed app is eligible at the
        // policy layer. HostController must still prove it is the sole bound
        // candidate before issuing a fresh connection-bound grant.
        #expect(await store.allowsAutoGrantUniqueWindow(
            requester: approvedRequester,
            window: recreatedWindow,
            capabilities: [.observe]
        ))
        #expect(await store.allowsAutoGrantUniqueWindow(
            requester: approvedRequester,
            window: approvedWindow,
            capabilities: [.observe, .interact]
        ))
        #expect(!(await store.allowsAutoGrantUniqueWindow(
            requester: approvedRequester,
            window: approvedWindow,
            capabilities: [.observe, .interact, .clipboardWrite]
        )))
        #expect(!(await store.allowsAutoGrantUniqueWindow(
            requester: requester(signingIdentity: "different-harness-signing-digest"),
            window: approvedWindow,
            capabilities: [.observe]
        )))
        #expect(!(await store.allowsAutoGrantUniqueWindow(
            requester: requester(bundleIdentifier: "com.example.claude"),
            window: approvedWindow,
            capabilities: [.observe]
        )))
        #expect(!(await store.allowsAutoGrantUniqueWindow(
            requester: approvedRequester,
            window: replacementSignedWindow,
            capabilities: [.observe]
        )))

        let persisted = try PersistentAppConsentStore(url: url)
        #expect(await persisted.allowsAutoGrantUniqueWindow(
            requester: approvedRequester,
            window: approvedWindow,
            capabilities: [.observe]
        ))
        let record = try #require((await persisted.all()).first)
        #expect(record.recordVersion == PersistentAppConsent.currentRecordVersion)
        #expect(record.policy == .autoGrantUniqueWindow)
        #expect(record.requesterBundleIdentifier == approvedRequester.harnessBundleIdentifier)
        #expect(record.requesterSigningIdentity == approvedRequester.harnessSigningIdentity)
    }

    @Test func legacyRecordAPICannotCreateOrUpgradeAutomaticAuthority() async throws {
        let root = try preferencesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("consent/apps.json")
        let store = try PersistentAppConsentStore(url: url)
        let window = try identity()

        try await store.record(window: window, capabilities: [.observe, .interact])
        #expect(await store.allows(window: window, capabilities: [.observe]))
        #expect(!(await store.allowsAutoGrantUniqueWindow(
            requester: requester(),
            window: window,
            capabilities: [.observe]
        )))
        let record = try #require((await store.all()).first)
        #expect(record.recordVersion == PersistentAppConsent.legacyRecordVersion)
        #expect(record.policy == .promptEachWindow)
    }

    @Test func unverifiedRequesterCannotCreateOrUseAutomaticAuthority() async throws {
        let root = try preferencesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("consent/apps.json")
        let store = try PersistentAppConsentStore(url: url)
        let unverified = requester(verified: false)
        let window = try identity()

        do {
            try await store.recordAutoGrantUniqueWindow(
                requester: unverified,
                window: window,
                capabilities: [.observe]
            )
            Issue.record("unverified requester created automatic consent")
        } catch {
            #expect(error as? ConsentStoreError == .unverifiedRequester)
        }
        #expect(!(await store.allowsAutoGrantUniqueWindow(
            requester: unverified,
            window: window,
            capabilities: [.observe]
        )))
        #expect((await store.all()).isEmpty)
    }

    @Test func exactRevokePreservesOtherHarnessPolicyForTheSameTarget() async throws {
        let root = try preferencesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("consent/apps.json")
        let store = try PersistentAppConsentStore(url: url)
        let window = try identity()
        let cursor = requester()
        let claude = requester(
            bundleIdentifier: "com.example.claude",
            signingIdentity: "claude-designated-requirement-digest"
        )
        try await store.recordAutoGrantUniqueWindow(
            requester: cursor,
            window: window,
            capabilities: [.observe]
        )
        try await store.recordAutoGrantUniqueWindow(
            requester: claude,
            window: window,
            capabilities: [.observe, .interact]
        )

        let records = await store.all()
        let cursorRecord = try #require(records.first {
            $0.requesterBundleIdentifier == cursor.harnessBundleIdentifier
        })
        #expect(records.count == 2)
        let revoked = try await store.revoke(cursorRecord)
        #expect(revoked)
        #expect(!(await store.allowsAutoGrantUniqueWindow(
            requester: cursor,
            window: window,
            capabilities: [.observe]
        )))
        #expect(await store.allowsAutoGrantUniqueWindow(
            requester: claude,
            window: window,
            capabilities: [.observe]
        ))
        #expect((await store.all()).count == 1)

        try await store.revoke(
            bundleIdentifier: window.bundleIdentifier,
            signingIdentity: window.signingIdentity
        )
        #expect((await store.all()).isEmpty)
    }

    @Test func malformedUnknownAndDuplicateRecordsFailClosed() throws {
        let validAuto = """
        {"bundleIdentifier":"com.example.fixture","capabilities":["observe"],"policy":"autoGrantUniqueWindow","recordVersion":2,"requesterBundleIdentifier":"com.example.cursor","requesterSigningIdentity":"cursor-designated-requirement-digest","signingIdentity":"designated-requirement-digest","updatedAt":"2026-08-30T00:00:00Z"}
        """
        let malformedRecords = [
            "not-json",
            """
            [{"bundleIdentifier":"com.example.fixture","capabilities":["observe"],"policy":"autoGrantUniqueWindow","recordVersion":2,"requesterBundleIdentifier":"com.example.cursor","signingIdentity":"designated-requirement-digest","updatedAt":"2026-08-30T00:00:00Z"}]
            """,
            """
            [{"bundleIdentifier":"com.example.fixture","capabilities":["observe"],"policy":"promptEachWindow","recordVersion":99,"signingIdentity":"designated-requirement-digest","updatedAt":"2026-08-30T00:00:00Z"}]
            """,
            "[\(validAuto),\(validAuto)]",
        ]

        for payload in malformedRecords {
            let root = try preferencesTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("consent/apps.json")
            try writeConsentFixture(payload, to: url)
            do {
                _ = try PersistentAppConsentStore(url: url)
                Issue.record("malformed consent store was accepted")
            } catch {
                #expect(error as? ConsentStoreError == .invalidRecord)
            }
        }
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
