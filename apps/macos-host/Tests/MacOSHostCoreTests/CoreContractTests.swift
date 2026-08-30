import AppKit
import Darwin
import Foundation
import Testing
@testable import MacOSHostCore

private enum FixtureFailure: Error { case expected; case unexpected }

private struct DisabledHostControlPolicyFixture: HostControlPolicyChecking {
    func isAppControlEnabled() async -> Bool { false }
}

private func temporaryDirectory(mode: mode_t = S_IRWXU) throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("computer-use-mcp-tests-\(UUID().uuidString)", isDirectory: true)
    guard mkdir(base.path, mode) == 0 else { throw FixtureFailure.unexpected }
    guard chmod(base.path, mode) == 0 else { throw FixtureFailure.unexpected }
    return base
}

private func shortTemporarySocketDirectory() throws -> URL {
    let suffix = UUID().uuidString.prefix(12)
    let base = URL(fileURLWithPath: "/tmp/cumcp-\(suffix)", isDirectory: true)
    guard mkdir(base.path, S_IRWXU) == 0 else { throw FixtureFailure.unexpected }
    guard chmod(base.path, S_IRWXU) == 0 else { throw FixtureFailure.unexpected }
    return base
}

private func fileMode(_ url: URL) throws -> mode_t {
    var status = stat()
    guard lstat(url.path, &status) == 0 else { throw FixtureFailure.unexpected }
    return status.st_mode & 0o777
}

private func makeDisplay(
    id: UInt32 = 42,
    origin: Point = Point(x: -1_440, y: 0),
    logical: Size = Size(width: 1_440, height: 900),
    pixels: Size = Size(width: 2_880, height: 1_800)
) throws -> DisplayIdentity {
    try DisplayIdentity(
        displayID: id,
        frame: Rect(origin: origin, size: logical),
        logicalSize: logical,
        pixelSize: pixels,
        pointPixelScaleX: pixels.width / logical.width,
        pointPixelScaleY: pixels.height / logical.height,
        name: "Fixture Display",
        isMain: false,
        isMirrored: false
    )
}

private func makeWindow(
    id: UInt32 = 700,
    bundle: String = "com.jmeguilos.computer-use-mcp.fixture",
    title: String = "Computer Use MCP Fixture — Primary"
) throws -> WindowDescriptor {
    let identity = try WindowIdentity(
        windowID: id,
        processID: 777,
        bundleIdentifier: bundle,
        ownerName: "Computer Use MCP Fixture",
        signingIdentity: String(repeating: "a", count: 64),
        processStartTimeUnixMs: 1_700_000_000_000
    )
    return try WindowDescriptor(
        identity: identity,
        title: title,
        frame: Rect(origin: Point(x: 120, y: 120), size: Size(width: 720, height: 520)),
        layer: 0,
        isOnScreen: true,
        isActive: true
    )
}

private func accessRequestParameters(bundleIdentifier: String) -> JSONValue {
    .object([
        "target": .object([
            "kind": .string("window"),
            "app": .object([
                "kind": .string("bundle_id"),
                "value": .string(bundleIdentifier),
            ]),
            "launchIfNeeded": .bool(false),
        ]),
        "reason": .string("Inspect the fixture"),
        "capabilities": .array([.string("observe")]),
        "timeoutMs": .number(5_000),
    ])
}

@Suite("Wire and connection contracts")
struct WireAndConnectionTests {
    @Test func codecRejectsUnknownFieldsAndOversizeFrames() throws {
        let unknown = Data(#"{"protocol":{"major":1,"minor":0},"id":"x","method":"status","surprise":true}"#.utf8)
        #expect(throws: WireCodecError.unknownField) { try WireCodec.decodeRequest(unknown) }
        #expect(throws: WireCodecError.frameTooLarge) {
            try WireCodec.decodeRequest(Data(repeating: 0x20, count: WireCodec.maximumLineBytes + 1))
        }
        #expect(WireCodec.maximumLineBytes == 8 * 1_024 * 1_024)
    }

    @Test func protocolCompatibilityIsDirectional() {
        #expect(ProtocolVersion.current.isCompatible(with: ProtocolVersion(major: 2, minor: 0)))
        #expect(!ProtocolVersion.current.isCompatible(with: ProtocolVersion(major: 2, minor: 1)))
        #expect(!ProtocolVersion.current.isCompatible(with: ProtocolVersion(major: 1, minor: 0)))
    }

    @Test func interactiveAccessGetsHumanDeadlineWithoutExpandingActionDeadline() {
        #expect(WireDeadlinePolicy.defaultMilliseconds(for: "requestAccess") == 120_000)
        #expect(WireDeadlinePolicy.maximumMilliseconds(for: "requestAccess") == 300_000)
        #expect(WireDeadlinePolicy.maximumMilliseconds(for: "action") == 30_000)
        #expect(WireDeadlinePolicy.defaultMilliseconds(for: "cancel") == 5_000)
    }

    @Test func connectionTokenOwnershipCapabilityAndIdleRefresh() async throws {
        let registry = ConnectionRegistry(idleTimeout: 900)
        let peer = PeerIdentity(uid: 501, processID: 77, name: "fixture", instanceID: "instance")
        let opened = try await registry.open(
            peer: peer,
            kernelUID: 501,
            kernelPID: 77,
            protocolVersion: .current,
            requestedCapabilities: [.inventoryRead],
            capabilityToken: String(repeating: "t", count: 43),
            now: Date(timeIntervalSince1970: 1_000)
        )
        do {
            _ = try await registry.touch(
                connectionID: opened.id,
                capabilityToken: String(repeating: "x", count: 43),
                requiring: .inventoryRead,
                now: Date(timeIntervalSince1970: 1_010)
            )
            Issue.record("wrong connection token was accepted")
        } catch { #expect(error as? ConnectionValidationError == .connectionTokenMismatch) }
        let refreshed = try await registry.touch(
            connectionID: opened.id,
            capabilityToken: opened.capabilityToken,
            requiring: .inventoryRead,
            now: Date(timeIntervalSince1970: 1_010)
        )
        #expect(refreshed.idleExpiresAt == Date(timeIntervalSince1970: 1_910))
        do {
            _ = try await registry.touch(
                connectionID: opened.id,
                capabilityToken: opened.capabilityToken,
                requiring: .syntheticInput,
                now: Date(timeIntervalSince1970: 1_011)
            )
            Issue.record("unnegotiated capability was accepted")
        } catch { #expect(error as? ConnectionValidationError == .capabilityDenied) }
    }

    @Test func bridgeDerivesBoundedRequesterIdentityAndHarnessAuthority() async throws {
        let harness = HarnessProcessIdentity(
            name: "  Fixture\u{0007} Harness  ",
            processID: 4_242,
            bundleIdentifier: "com.example.fixture-harness",
            signingIdentity: "fixture-signing",
            processStartTimeUnixMs: 1_700_000_000_000
        )
        let peer = BridgeClientIdentityPolicy.makePeer(
            harness: harness,
            bridgeUID: 501,
            bridgeProcessID: 7_777,
            bridgeInstanceID: "bridge-instance"
        )
        #expect(peer.name == "Fixture Harness")
        #expect(peer.processID == 7_777)
        #expect(peer.instanceID == "bridge-instance")
        #expect(peer.harnessIdentityVerified)

        let window = try WindowIdentity(
            windowID: 99,
            processID: harness.processID,
            bundleIdentifier: harness.bundleIdentifier,
            ownerName: "Fixture Harness",
            signingIdentity: harness.signingIdentity,
            processStartTimeUnixMs: harness.processStartTimeUnixMs
        )
        #expect(peer.matchesHarnessWindow(window))
        #expect(peer.matchesHarnessApplication(bundleIdentifier: harness.bundleIdentifier))
        #expect(peer.captureExclusion?.matches(window) == true)

        let registry = ConnectionRegistry(
            harnessIdentityValidator: ToggleHarnessIdentityValidatorFixture(isCurrent: true)
        )
        _ = try await registry.open(
            peer: peer,
            kernelUID: 501,
            kernelPID: 7_777,
            protocolVersion: .current,
            requestedCapabilities: [.inventoryRead],
            capabilityToken: String(repeating: "b", count: 43)
        )
    }

    @Test func connectionRevokesWhenDerivedHarnessGenerationDisappears() async throws {
        let validator = ToggleHarnessIdentityValidatorFixture(isCurrent: true)
        let registry = ConnectionRegistry(harnessIdentityValidator: validator)
        let peer = PeerIdentity(
            uid: 501,
            processID: 7_777,
            name: "Verified Fixture",
            instanceID: "bridge-instance",
            harnessProcessID: 4_242,
            harnessBundleIdentifier: "com.example.verified",
            harnessSigningIdentity: "verified-signing",
            harnessProcessStartTimeUnixMs: 1_700_000_000_000,
            harnessIdentityVerified: true
        )
        let opened = try await registry.open(
            peer: peer,
            kernelUID: 501,
            kernelPID: 7_777,
            protocolVersion: .current,
            requestedCapabilities: [.inventoryRead],
            capabilityToken: String(repeating: "b", count: 43)
        )
        validator.setCurrent(false)
        do {
            _ = try await registry.touch(
                connectionID: opened.id,
                capabilityToken: opened.capabilityToken,
                requiring: .inventoryRead
            )
            Issue.record("stale derived harness identity remained authorized")
        } catch {
            #expect(error as? ConnectionValidationError == .peerIdentityChanged)
        }
        #expect(await registry.record(connectionID: opened.id) == nil)
    }

    @Test func connectionRejectsUnverifiedHarnessClaimsAndFallsBackTruthfully() async throws {
        let fallback = BridgeClientIdentityPolicy.makePeer(
            harness: nil,
            bridgeUID: 501,
            bridgeProcessID: 7_777,
            bridgeInstanceID: "bridge-instance"
        )
        #expect(fallback.name == "Unidentified local MCP harness")
        #expect(!fallback.harnessIdentityVerified)
        #expect(fallback.captureExclusion == nil)

        let incoherent = PeerIdentity(
            uid: 501,
            processID: 7_777,
            name: "spoofed",
            instanceID: "instance",
            harnessProcessID: 4_242,
            harnessIdentityVerified: false
        )
        let registry = ConnectionRegistry()
        do {
            _ = try await registry.open(
                peer: incoherent,
                kernelUID: 501,
                kernelPID: 7_777,
                protocolVersion: .current,
                requestedCapabilities: [.inventoryRead],
                capabilityToken: String(repeating: "b", count: 43)
            )
            Issue.record("unverified harness identity fields were accepted")
        } catch {
            #expect(error as? ConnectionValidationError == .unauthenticated)
        }
    }

    @Test func bridgeHelloIgnoresCallerSuppliedRequesterLabels() throws {
        let root = URL(fileURLWithPath: "/tmp/computer-use-mcp-bridge-policy-test", isDirectory: true)
        let configuration = SocketConfiguration(
            runtimeDirectory: root,
            socketURL: root.appendingPathComponent("host.sock"),
            authenticationTokenURL: root.appendingPathComponent("auth.token")
        )
        let harness = HarnessProcessIdentity(
            name: "Verified Fixture",
            processID: 4_242,
            bundleIdentifier: "com.example.verified",
            signingIdentity: "verified-signing",
            processStartTimeUnixMs: 1_700_000_000_000
        )
        let proxy = BridgeProxy(
            configuration: configuration,
            input: .nullDevice,
            output: .nullDevice,
            diagnostics: .nullDevice,
            harnessIdentity: harness,
            bridgeInstanceID: "bridge-owned-instance"
        )
        let incoming = Data(#"{"protocol":{"major":1,"minor":0},"id":"hello","method":"hello","client":{"name":"Spoofed Name","instanceId":"spoofed-instance","uid":1,"pid":123}}"#.utf8)
        let transformed = try proxy.transform(
            incoming,
            authenticationToken: String(repeating: "a", count: 43),
            first: true
        )
        let object = try #require(JSONSerialization.jsonObject(with: transformed) as? [String: Any])
        let client = try #require(object["client"] as? [String: Any])
        #expect(client["name"] as? String == "Verified Fixture")
        #expect(client["instanceId"] as? String == "bridge-owned-instance")
        #expect((client["pid"] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier)
        #expect((client["harnessProcessID"] as? NSNumber)?.int32Value == harness.processID)
        #expect(client["harnessIdentityVerified"] as? Bool == true)
    }

    @Test func handshakeReplayGuardRejectsNonceReuse() async throws {
        let replay = HandshakeReplayGuard(lifetime: 900)
        let now = Date(timeIntervalSince1970: 10)
        try await replay.consume(nonce: String(repeating: "n", count: 22), now: now)
        do {
            try await replay.consume(nonce: String(repeating: "n", count: 22), now: now)
            Issue.record("replayed nonce was accepted")
        } catch { #expect(error as? LocalSecurityError == .replayedHandshake) }
    }

    @Test func authenticatedRouterValidatesTokensDeadlinesAndFixtureShapes() async throws {
        let peer = SocketPeerCredentials(uid: 501, processID: 777, auditToken: Data(repeating: 1, count: 32))
        let handler = FixtureWireHandler()
        let session = WireConnectionSession(
            peer: peer,
            authenticationToken: String(repeating: "a", count: 43),
            connections: ConnectionRegistry(),
            replayGuard: HandshakeReplayGuard(),
            handler: handler
        )
        let hello = await session.dispatch(WireRequest(
            id: "hello-1",
            method: "hello",
            auth: WireAuthentication(token: String(repeating: "a", count: 43)),
            client: PeerIdentity(uid: 501, processID: 777, name: "codex", instanceID: "fixture-instance"),
            capabilities: Set(HostCapability.allCases),
            nonce: String(repeating: "n", count: 22)
        ))
        #expect(hello.ok)
        guard let result = hello.result?.objectValue,
              let connectionText = result["connectionId"]?.stringValue,
              let connectionID = UUID(uuidString: connectionText),
              let connectionToken = result["connectionToken"]?.stringValue else {
            Issue.record("hello response omitted connection authority")
            return
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let access = await session.dispatch(WireRequest(
            id: "access-1", method: "requestAccess",
            connectionID: connectionID, connectionToken: connectionToken,
            deadlineUnixMs: nowMs + 120_000,
            params: .object(["fixture": .bool(true)])
        ))
        #expect(access.ok)
        #expect(access.result?.objectValue?["grantId"] == .string("fixture-grant-0001"))

        let overlongAction = await session.dispatch(WireRequest(
            id: "action-long", method: "action",
            connectionID: connectionID, connectionToken: connectionToken,
            deadlineUnixMs: nowMs + 120_000, params: .object([:])
        ))
        #expect(!overlongAction.ok)
        #expect(overlongAction.error?.code == "ACTION_TIMEOUT")

        let wrongToken = await session.dispatch(WireRequest(
            id: "status-wrong", method: "status",
            connectionID: connectionID, connectionToken: String(repeating: "x", count: 43),
            deadlineUnixMs: nowMs + 5_000, params: .object([:])
        ))
        #expect(!wrongToken.ok)
        #expect(wrongToken.error?.code == "AUTH_FAILED")

        let first = await session.dispatch(WireRequest(
            id: "duplicate", method: "status",
            connectionID: connectionID, connectionToken: connectionToken,
            deadlineUnixMs: nowMs + 5_000, params: .object([:])
        ))
        #expect(first.ok)
        let duplicate = await session.dispatch(WireRequest(
            id: "duplicate", method: "status",
            connectionID: connectionID, connectionToken: connectionToken,
            deadlineUnixMs: nowMs + 5_000, params: .object([:])
        ))
        #expect(!duplicate.ok)
        await session.close()
        #expect(await handler.disconnectCount == 1)
    }
}

@Suite("Runtime and peer security", .serialized)
struct RuntimeSecurityTests {
    @Test func canonicalSocketAndEnvironmentNamesAreStable() throws {
        let configuration = try SocketConfiguration.resolved(environment: [:])
        #expect(CanonicalRuntime.socketEnvironmentKey == "COMPUTER_USE_MCP_SOCKET_PATH")
        #expect(configuration.socketURL.path.hasSuffix("ComputerUseMCP/runtime/host.sock"))
        #expect(CanonicalRuntime.bridgeBundleIdentifier == "com.jmeguilos.computer-use-mcp.bridge")
        #expect(CanonicalRuntime.hostBundleIdentifier == "com.jmeguilos.computer-use-mcp.host")
    }

    @Test func existingWrongModeOverrideIsRejectedWithoutMutation() throws {
        let directory = try temporaryDirectory(mode: 0o755)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = SocketConfiguration(
            runtimeDirectory: directory,
            socketURL: directory.appendingPathComponent("host.sock"),
            authenticationTokenURL: directory.appendingPathComponent("auth.token")
        )
        #expect(throws: LocalSecurityError.permissionMismatch) {
            try RuntimeCredentialStore(configuration: configuration).prepare()
        }
        #expect(try fileMode(directory) == 0o755)
    }

    @Test func dedicatedRuntimeCreatesPrivateTokenAndLoadsIt() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runtime = parent.appendingPathComponent("runtime")
        let configuration = SocketConfiguration(
            runtimeDirectory: runtime,
            socketURL: runtime.appendingPathComponent("host.sock"),
            authenticationTokenURL: runtime.appendingPathComponent("auth.token")
        )
        let token = try RuntimeCredentialStore(configuration: configuration).prepare()
        #expect(token.count >= 43)
        #expect(try fileMode(runtime) == 0o700)
        #expect(try fileMode(configuration.authenticationTokenURL) == 0o600)
        #expect(try RuntimeCredentialStore(configuration: configuration).loadExisting() == token)
    }

    @Test func sensitiveReadsRejectSymlinksAndWrongOwnerFromOpenedDescriptor() throws {
        let runtime = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: runtime) }
        let realToken = runtime.appendingPathComponent("real.token")
        let token = String(repeating: "t", count: 43)
        guard FileManager.default.createFile(
            atPath: realToken.path,
            contents: Data(token.utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else { throw FixtureFailure.unexpected }
        let tokenLink = runtime.appendingPathComponent("auth.token")
        try FileManager.default.createSymbolicLink(
            atPath: tokenLink.path,
            withDestinationPath: realToken.path
        )
        let configuration = SocketConfiguration(
            runtimeDirectory: runtime,
            socketURL: runtime.appendingPathComponent("host.sock"),
            authenticationTokenURL: tokenLink
        )
        #expect(throws: LocalSecurityError.symbolicLinkRejected) {
            try RuntimeCredentialStore(configuration: configuration).loadExisting()
        }

        #expect(throws: LocalSecurityError.ownerMismatch) {
            _ = try SecureFileIO.readIfExists(
                path: realToken.path,
                requiredMode: 0o600,
                maximumBytes: 4_096,
                expectedUID: getuid() &+ 1
            )
        }

        let markerTarget = runtime.appendingPathComponent("marker-target")
        guard FileManager.default.createFile(
            atPath: markerTarget.path,
            contents: Data(DevelopmentModeAuthorization.markerContents.utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else { throw FixtureFailure.unexpected }
        let marker = runtime.appendingPathComponent(DevelopmentModeAuthorization.markerFileName)
        try FileManager.default.createSymbolicLink(atPath: marker.path, withDestinationPath: markerTarget.path)
        #expect(!DevelopmentModeAuthorization.validate(configuration: configuration))
    }

    @Test func developmentVerifierFailsClosed() throws {
        let peer = SocketPeerCredentials(uid: UInt32(getuid()), processID: 999, auditToken: Data([1]))
        #expect(throws: LocalSecurityError.developmentModeDisabled) {
            try ExplicitDevelopmentPeerCodeVerifier(explicitlyEnabled: false).verify(peer)
        }
        #expect(throws: LocalSecurityError.peerUIDMismatch) {
            try ExplicitDevelopmentPeerCodeVerifier(
                explicitlyEnabled: true,
                expectedUID: UInt32(getuid()) &+ 1
            ).verify(peer)
        }
    }

    @Test func bridgeAuthenticatesTheConnectedHostBeforeSendingFrames() throws {
        let directory = URL(fileURLWithPath: "/tmp/computer-use-mcp-host-auth-test", isDirectory: true)
        let configuration = SocketConfiguration(
            runtimeDirectory: directory,
            socketURL: directory.appendingPathComponent("host.sock"),
            authenticationTokenURL: directory.appendingPathComponent("auth.token")
        )
        let peer = SocketPeerCredentials(
            uid: UInt32(getuid()),
            processID: 4_242,
            auditToken: Data(repeating: 1, count: 32)
        )
        let accepted = BridgeProxy(
            configuration: configuration,
            input: .nullDevice,
            output: .nullDevice,
            diagnostics: .nullDevice,
            harnessIdentity: nil,
            bridgeInstanceID: "test",
            serverPeerInspector: SocketPeerInspectorFixture(peer: peer),
            serverPeerVerifier: AcceptingPeerVerifierFixture()
        )
        try accepted.authenticateServer(socket: -1)

        let rejected = BridgeProxy(
            configuration: configuration,
            input: .nullDevice,
            output: .nullDevice,
            diagnostics: .nullDevice,
            harnessIdentity: nil,
            bridgeInstanceID: "test",
            serverPeerInspector: SocketPeerInspectorFixture(peer: peer),
            serverPeerVerifier: RejectingPeerVerifierFixture()
        )
        #expect(throws: LocalSecurityError.signatureRejected) {
            try rejected.authenticateServer(socket: -1)
        }

        let wrongUID = BridgeProxy(
            configuration: configuration,
            input: .nullDevice,
            output: .nullDevice,
            diagnostics: .nullDevice,
            harnessIdentity: nil,
            bridgeInstanceID: "test",
            serverPeerInspector: SocketPeerInspectorFixture(peer: SocketPeerCredentials(
                uid: UInt32(getuid()) &+ 1,
                processID: 4_242,
                auditToken: Data(repeating: 1, count: 32)
            )),
            serverPeerVerifier: AcceptingPeerVerifierFixture()
        )
        #expect(throws: LocalSecurityError.peerCredentialUnavailable) {
            try wrongUID.authenticateServer(socket: -1)
        }
    }

    @Test func bridgePinsTheHostExecutableInsideTheSameAppBundle() {
        let installedBridge = URL(fileURLWithPath: "/Users/fixture/ComputerUseMCPHost.app/Contents/Helpers/ComputerUseMCPBridge")
        #expect(
            BridgeHostPeerVerifierFactory.hostExecutableURL(forBridgeExecutable: installedBridge).path ==
                "/Users/fixture/ComputerUseMCPHost.app/Contents/MacOS/ComputerUseMCPHost"
        )
        let buildBridge = URL(fileURLWithPath: "/tmp/build/ComputerUseMCPBridge")
        #expect(
            BridgeHostPeerVerifierFactory.hostExecutableURL(forBridgeExecutable: buildBridge).path ==
                "/tmp/build/ComputerUseMCPHost"
        )
    }

    @Test func peerVerifierPolicySupportsPermissionRelaunchWithoutDowngradingReleases() {
        #expect(PeerVerifierPolicy.select(
            signingIdentity: .adHoc,
            sourceAuthorizationValid: true
        ) == .sourceDevelopment)
        #expect(PeerVerifierPolicy.select(
            signingIdentity: .adHoc,
            sourceAuthorizationValid: false
        ) == .denied)
        #expect(PeerVerifierPolicy.select(
            signingIdentity: .release(teamIdentifier: "TEAM123456"),
            sourceAuthorizationValid: true
        ) == .release(teamIdentifier: "TEAM123456"))
        #expect(PeerVerifierPolicy.select(
            signingIdentity: .release(teamIdentifier: "TEAM123456"),
            sourceAuthorizationValid: false
        ) == .release(teamIdentifier: "TEAM123456"))
    }

    @Test func signingIdentityClassificationFailsClosed() throws {
        #expect(try CurrentCodeIdentity.classify(
            signingFlags: CurrentCodeIdentity.adHocSignatureFlag,
            teamIdentifier: nil
        ) == .adHoc)
        #expect(try CurrentCodeIdentity.classify(
            signingFlags: 0,
            teamIdentifier: " TEAM123456 "
        ) == .release(teamIdentifier: "TEAM123456"))
        #expect(throws: LocalSecurityError.signatureRejected) {
            try CurrentCodeIdentity.classify(
                signingFlags: CurrentCodeIdentity.adHocSignatureFlag,
                teamIdentifier: "TEAM123456"
            )
        }
        #expect(throws: LocalSecurityError.missingTeamIdentifier) {
            try CurrentCodeIdentity.classify(signingFlags: 0, teamIdentifier: nil)
        }
        #expect(throws: LocalSecurityError.missingTeamIdentifier) {
            try CurrentCodeIdentity.classify(signingFlags: 0, teamIdentifier: " \n\t ")
        }
    }

    @Test func maintenanceRunsWhileListenerAcceptIsBlocked() async throws {
        // Darwin sockaddr_un paths are short. Hosted-runner TMPDIR values can
        // exceed that bound before the fixture even appends `host.sock`.
        let directory = try shortTemporarySocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = SocketConfiguration(
            runtimeDirectory: directory,
            socketURL: directory.appendingPathComponent("host.sock"),
            authenticationTokenURL: directory.appendingPathComponent("auth.token")
        )
        let handler = MaintenanceHandlerFixture()
        let server = HostSocketServer(
            configuration: configuration,
            authenticationToken: String(repeating: "t", count: 43),
            peerVerifier: AcceptingPeerVerifierFixture(),
            handler: handler,
            maintenanceInterval: 0.05
        )
        try server.start()
        try await Task.sleep(nanoseconds: 250_000_000)
        server.stop()
        #expect(await handler.maintenanceCount > 0)
    }
}

@Suite("Grant, frame, and transform authority")
struct GrantFrameTransformTests {
    @Test func globalAppControlGateIsFailClosedButStatusAndReleaseRemainAvailable() async throws {
        let controller = HostController(controlPolicy: DisabledHostControlPolicyFixture())
        let now = Date()
        let connection = ConnectionRecord(
            id: UUID(), capabilityToken: String(repeating: "t", count: 43),
            peer: PeerIdentity(
                uid: UInt32(getuid()), processID: 777,
                name: "fixture-harness", instanceID: "fixture"
            ),
            capabilities: Set(HostCapability.allCases), openedAt: now,
            lastActivityAt: now, idleTimeout: 900
        )
        let context = HostRequestContext(
            requestID: "disabled-policy", connection: connection,
            deadline: now.addingTimeInterval(30)
        )

        let status = try await controller.handle(
            method: "status", params: .object([:]), context: context
        )
        #expect(status.objectValue?["status"] == .string("degraded"))
        #expect(status.objectValue?["appControlEnabled"] == .bool(false))

        do {
            _ = try await controller.handle(
                method: "listApps", params: .object([:]), context: context
            )
            Issue.record("disabled global app control exposed application inventory")
        } catch {
            #expect((error as? WireError)?.code == "APP_CONTROL_DISABLED")
        }

        let unknownGrant = UUID()
        let release = try await controller.handle(
            method: "releaseAccess",
            params: .object([
                "grantId": .string(unknownGrant.uuidString),
                "timeoutMs": .number(10_000),
            ]),
            context: context
        )
        #expect(release.objectValue?["status"] == .string("not_found"))
    }

    @Test func absentApplicationLaunchRequiresSeparateConsentBeforeMutation() async throws {
        let capture = EmptyCaptureServiceFixture()
        let presenter = LaunchDenyingPresenterFixture()
        let launcher = RecordingApplicationLauncherFixture()
        let controller = HostController(
            capture: capture,
            accessPresenter: presenter,
            applicationLauncher: launcher
        )
        let now = Date()
        let connection = ConnectionRecord(
            id: UUID(), capabilityToken: String(repeating: "t", count: 43),
            peer: PeerIdentity(uid: UInt32(getuid()), processID: 777, name: "fixture-harness", instanceID: "fixture"),
            capabilities: Set(HostCapability.allCases), openedAt: now,
            lastActivityAt: now, idleTimeout: 900
        )
        let result = try await controller.handle(
            method: "requestAccess",
            params: .object([
                "target": .object([
                    "kind": .string("window"),
                    "app": .object(["kind": .string("bundle_id"), "value": .string("com.example.absent")]),
                    "launchIfNeeded": .bool(true),
                ]),
                "reason": .string("Inspect the fixture"),
                "capabilities": .array([.string("observe")]),
                "timeoutMs": .number(120_000),
            ]),
            context: HostRequestContext(
                requestID: "launch-consent", connection: connection,
                deadline: now.addingTimeInterval(120)
            )
        )
        #expect(result.objectValue?["status"] == .string("denied"))
        #expect(launcher.launchCount == 0)
        #expect(presenter.lastLaunchRequest?.bundleIdentifier == "com.example.absent")
        #expect(presenter.lastLaunchRequest?.reason == "Inspect the fixture")
    }

    @Test func pathSelectorLaunchIfNeededFailsClosedBeforeExecution() async throws {
        let launcher = RecordingApplicationLauncherFixture()
        let controller = HostController(
            capture: EmptyCaptureServiceFixture(),
            accessPresenter: LaunchAcceptingPresenterFixture(),
            applicationLauncher: launcher
        )
        let now = Date()
        let connection = ConnectionRecord(
            id: UUID(), capabilityToken: String(repeating: "t", count: 43),
            peer: PeerIdentity(uid: UInt32(getuid()), processID: 777, name: "fixture-harness", instanceID: "fixture"),
            capabilities: Set(HostCapability.allCases), openedAt: now,
            lastActivityAt: now, idleTimeout: 900
        )
        do {
            _ = try await controller.handle(
                method: "requestAccess",
                params: .object([
                    "target": .object([
                        "kind": .string("window"),
                        "app": .object([
                            "kind": .string("path"),
                            "value": .string("/Applications/Untrusted Fixture.app"),
                        ]),
                        "launchIfNeeded": .bool(true),
                    ]),
                    "reason": .string("Inspect the fixture"),
                    "capabilities": .array([.string("observe")]),
                    "timeoutMs": .number(120_000),
                ]),
                context: HostRequestContext(
                    requestID: "path-launch-denied", connection: connection,
                    deadline: now.addingTimeInterval(120)
                )
            )
            Issue.record("path launch unexpectedly executed")
        } catch {
            #expect(WireErrorMapping.map(error).code == "ACCESS_DENIED")
        }
        #expect(launcher.launchCount == 0)
    }

    @Test func approvedLaunchPollsUntilFirstWindowIsInventoryVisible() async throws {
        let app = ApplicationDescriptor(
            bundleIdentifier: "com.example.absent",
            name: "Absent Fixture",
            processID: 777,
            bundleURLPath: "/Applications/Absent Fixture.app",
            windows: [try makeWindow(bundle: "com.example.absent", title: "First Window")],
            isProtected: false
        )
        let capture = ProgressiveCaptureServiceFixture(application: app, visibleAfterInventoryCall: 3)
        let presenter = LaunchAcceptingPresenterFixture()
        let launcher = RecordingApplicationLauncherFixture()
        let controller = HostController(
            capture: capture,
            permissions: GrantedPermissionFixture(),
            accessPresenter: presenter,
            applicationLauncher: launcher
        )
        let now = Date()
        let connection = ConnectionRecord(
            id: UUID(), capabilityToken: String(repeating: "t", count: 43),
            peer: PeerIdentity(uid: UInt32(getuid()), processID: 777, name: "fixture-harness", instanceID: "fixture"),
            capabilities: Set(HostCapability.allCases), openedAt: now,
            lastActivityAt: now, idleTimeout: 900
        )
        let result = try await controller.handle(
            method: "requestAccess",
            params: .object([
                "target": .object([
                    "kind": .string("window"),
                    "app": .object(["kind": .string("bundle_id"), "value": .string("com.example.absent")]),
                    "launchIfNeeded": .bool(true),
                ]),
                "reason": .string("Inspect the fixture"),
                "capabilities": .array([.string("observe")]),
                "timeoutMs": .number(120_000),
            ]),
            context: HostRequestContext(
                requestID: "launch-poll", connection: connection,
                deadline: now.addingTimeInterval(120)
            )
        )
        #expect(result.objectValue?["status"] == .string("granted"))
        #expect(
            result.objectValue?["target"]?.objectValue?["app"]?.objectValue?["bundlePath"] ==
                .string("/Applications/Absent Fixture.app")
        )
        #expect(launcher.launchCount == 1)
        #expect(await capture.inventoryCallCount() >= 3)
        guard let grantID = result.objectValue?["grantId"]?.stringValue else {
            Issue.record("grant response omitted its identifier")
            return
        }
        let released = try await controller.handle(
            method: "releaseAccess",
            params: .object(["grantId": .string(grantID)]),
            context: HostRequestContext(
                requestID: "release-after-launch", connection: connection,
                deadline: Date().addingTimeInterval(5)
            )
        )
        #expect(released.objectValue?["status"] == .string("released"))
    }

    @Test func canceledAccessRequestReachesTheVisiblePresenterAndPublishesNoGrant() async throws {
        let app = ApplicationDescriptor(
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            processID: 777,
            bundleURLPath: "/Applications/Fixture.app",
            windows: [try makeWindow(bundle: "com.example.fixture", title: "Primary")],
            isProtected: false
        )
        let presenter = CancellationObservingPresenterFixture()
        let controller = HostController(
            capture: ProgressiveCaptureServiceFixture(application: app, visibleAfterInventoryCall: 1),
            permissions: GrantedPermissionFixture(),
            accessPresenter: presenter
        )
        let now = Date()
        let connection = ConnectionRecord(
            id: UUID(), capabilityToken: String(repeating: "t", count: 43),
            peer: PeerIdentity(uid: UInt32(getuid()), processID: 777, name: "fixture-harness", instanceID: "fixture"),
            capabilities: Set(HostCapability.allCases), openedAt: now,
            lastActivityAt: now, idleTimeout: 900
        )
        let task = Task {
            try await controller.handle(
                method: "requestAccess",
                params: accessRequestParameters(bundleIdentifier: "com.example.fixture"),
                context: HostRequestContext(
                    requestID: "cancel-visible-picker",
                    connection: connection,
                    deadline: now.addingTimeInterval(5)
                )
            )
        }
        #expect(await presenter.waitUntilPresented())
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("canceled access request unexpectedly completed")
        } catch {
            #expect(WireErrorMapping.map(error).code == "CANCELLED")
        }
        #expect(await presenter.observedCancellation)
        let status = try await controller.handle(
            method: "status",
            params: .object([:]),
            context: HostRequestContext(
                requestID: "status-after-picker-cancel",
                connection: connection,
                deadline: Date().addingTimeInterval(5)
            )
        )
        #expect(status.objectValue?["activeGrants"] == .array([]))
    }

    @Test func disconnectCancelsVisibleAccessPresenterWithoutLateAuthority() async throws {
        let app = ApplicationDescriptor(
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            processID: 777,
            bundleURLPath: "/Applications/Fixture.app",
            windows: [try makeWindow(bundle: "com.example.fixture", title: "Primary")],
            isProtected: false
        )
        let presenter = CancellationObservingPresenterFixture()
        let controller = HostController(
            capture: ProgressiveCaptureServiceFixture(application: app, visibleAfterInventoryCall: 1),
            permissions: GrantedPermissionFixture(),
            accessPresenter: presenter
        )
        let now = Date()
        let connection = ConnectionRecord(
            id: UUID(), capabilityToken: String(repeating: "t", count: 43),
            peer: PeerIdentity(uid: UInt32(getuid()), processID: 777, name: "fixture-harness", instanceID: "fixture"),
            capabilities: Set(HostCapability.allCases), openedAt: now,
            lastActivityAt: now, idleTimeout: 900
        )
        let task = Task {
            try await controller.handle(
                method: "requestAccess",
                params: accessRequestParameters(bundleIdentifier: "com.example.fixture"),
                context: HostRequestContext(
                    requestID: "disconnect-visible-picker",
                    connection: connection,
                    deadline: now.addingTimeInterval(5)
                )
            )
        }
        #expect(await presenter.waitUntilPresented())
        await controller.disconnect(connectionID: connection.id)
        do {
            _ = try await task.value
            Issue.record("disconnected access request unexpectedly completed")
        } catch {
            #expect(WireErrorMapping.map(error).code == "CANCELLED")
        }
        #expect(await presenter.observedCancellation)
    }

    @Test func accessDeadlineCancelsAnUnansweredVisiblePresenter() async throws {
        let app = ApplicationDescriptor(
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            processID: 777,
            bundleURLPath: "/Applications/Fixture.app",
            windows: [try makeWindow(bundle: "com.example.fixture", title: "Primary")],
            isProtected: false
        )
        let presenter = CancellationObservingPresenterFixture()
        let controller = HostController(
            capture: ProgressiveCaptureServiceFixture(application: app, visibleAfterInventoryCall: 1),
            permissions: GrantedPermissionFixture(),
            accessPresenter: presenter
        )
        let now = Date()
        let connection = ConnectionRecord(
            id: UUID(), capabilityToken: String(repeating: "t", count: 43),
            peer: PeerIdentity(uid: UInt32(getuid()), processID: 777, name: "fixture-harness", instanceID: "fixture"),
            capabilities: Set(HostCapability.allCases), openedAt: now,
            lastActivityAt: now, idleTimeout: 900
        )
        do {
            _ = try await controller.handle(
                method: "requestAccess",
                params: accessRequestParameters(bundleIdentifier: "com.example.fixture"),
                context: HostRequestContext(
                    requestID: "deadline-visible-picker",
                    connection: connection,
                    deadline: now.addingTimeInterval(0.15)
                )
            )
            Issue.record("expired access picker unexpectedly completed")
        } catch {
            #expect(WireErrorMapping.map(error).code == "ACTION_TIMEOUT")
        }
        #expect(await presenter.observedCancellation)
    }

    @Test func failedMandatoryIndicatorNeverPublishesGrantAuthority() async throws {
        let app = ApplicationDescriptor(
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            processID: 777,
            windows: [try makeWindow(bundle: "com.example.fixture", title: "Primary")],
            isProtected: false
        )
        let controller = HostController(
            capture: ProgressiveCaptureServiceFixture(application: app, visibleAfterInventoryCall: 1),
            permissions: GrantedPermissionFixture(),
            accessPresenter: LaunchAcceptingPresenterFixture(),
            indicator: FailingIndicatorFixture()
        )
        let now = Date()
        let connection = ConnectionRecord(
            id: UUID(), capabilityToken: String(repeating: "t", count: 43),
            peer: PeerIdentity(uid: UInt32(getuid()), processID: 777, name: "fixture-harness", instanceID: "fixture"),
            capabilities: Set(HostCapability.allCases), openedAt: now,
            lastActivityAt: now, idleTimeout: 900
        )
        do {
            _ = try await controller.handle(
                method: "requestAccess",
                params: .object([
                    "target": .object([
                        "kind": .string("window"),
                        "app": .object(["kind": .string("bundle_id"), "value": .string("com.example.fixture")]),
                        "launchIfNeeded": .bool(false),
                    ]),
                    "reason": .string("Inspect the fixture"),
                    "capabilities": .array([.string("observe")]),
                    "timeoutMs": .number(120_000),
                ]),
                context: HostRequestContext(
                    requestID: "indicator-failure", connection: connection,
                    deadline: now.addingTimeInterval(120)
                )
            )
            Issue.record("grant was issued without a visible indicator")
        } catch {
            #expect(WireErrorMapping.map(error).code == "INTERNAL_ERROR")
        }
        let status = try await controller.handle(
            method: "status", params: .object([:]),
            context: HostRequestContext(
                requestID: "status-after-indicator-failure", connection: connection,
                deadline: Date().addingTimeInterval(5)
            )
        )
        #expect(status.objectValue?["activeGrants"] == .array([]))
    }

    @Test func windowCaptureIdentityIncludesProcessGeneration() throws {
        let window = try makeWindow()
        let reused = try WindowIdentity(
            windowID: window.identity.windowID,
            processID: window.identity.processID,
            bundleIdentifier: window.identity.bundleIdentifier,
            ownerName: window.identity.ownerName,
            signingIdentity: window.identity.signingIdentity,
            processStartTimeUnixMs: window.identity.processStartTimeUnixMs + 1
        )
        #expect(ScreenCaptureService.matchesExpectedIdentity(window, expectedIdentity: window.identity))
        #expect(!ScreenCaptureService.matchesExpectedIdentity(window, expectedIdentity: reused))
        #expect(WireErrorMapping.map(CaptureError.targetIdentityChanged).code == "WINDOW_CLOSED")
    }

    @Test func inventoryOmitsOwnerlessAndInvalidApplicationIdentities() {
        let ownBundle = "com.jmeguilos.computer-use-mcp.host"
        #expect(ScreenCaptureService.isInventoryApplicationIdentity(
            processID: 700,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            ownBundleIdentifier: ownBundle
        ))
        for (processID, bundleIdentifier, name) in [
            (Int32(0), "com.example.fixture", "Fixture"),
            (Int32(700), "", ""),
            (Int32(700), "   ", "Fixture"),
            (Int32(700), "com.example.fixture", "\n"),
            (Int32(700), ownBundle, "Computer Use MCP Host"),
        ] {
            #expect(!ScreenCaptureService.isInventoryApplicationIdentity(
                processID: processID,
                bundleIdentifier: bundleIdentifier,
                name: name,
                ownBundleIdentifier: ownBundle
            ))
        }
    }

    @Test func windowIdentityPolicyRejectsBlankOrWhitespaceOwnerNames() {
        #expect(ScreenCaptureService.isUsableApplicationIdentity(
            processID: 700,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        ))
        for name in ["", " ", "\n", "\t\r"] {
            #expect(!ScreenCaptureService.isUsableApplicationIdentity(
                processID: 700,
                bundleIdentifier: "com.example.fixture",
                name: name
            ))
        }
    }

    @Test func listAppsFailsClosedOnInvalidCaptureProviderIdentity() async throws {
        let invalidApplication = ApplicationDescriptor(
            bundleIdentifier: "",
            name: "",
            processID: 700,
            windows: [],
            isProtected: false
        )
        let controller = HostController(
            capture: ProgressiveCaptureServiceFixture(
                application: invalidApplication,
                visibleAfterInventoryCall: 1
            )
        )
        let now = Date()
        let connection = ConnectionRecord(
            id: UUID(),
            capabilityToken: String(repeating: "t", count: 43),
            peer: PeerIdentity(
                uid: UInt32(getuid()),
                processID: 777,
                name: "fixture-harness",
                instanceID: "fixture"
            ),
            capabilities: Set(HostCapability.allCases),
            openedAt: now,
            lastActivityAt: now,
            idleTimeout: 900
        )
        let result = try await controller.handle(
            method: "listApps",
            params: .object([:]),
            context: HostRequestContext(
                requestID: "invalid-application-inventory",
                connection: connection,
                deadline: now.addingTimeInterval(5)
            )
        )
        #expect(result.objectValue?["apps"] == .array([]))
    }

    @Test func listAppsNeverMarksTheVerifiedRequestingHarnessGrantable() async throws {
        let bundleIdentifier = "com.example.verified-harness"
        let window = try makeWindow(
            id: 7_101,
            bundle: bundleIdentifier,
            title: "Harness Window"
        )
        let application = ApplicationDescriptor(
            bundleIdentifier: bundleIdentifier,
            name: "Verified Harness",
            processID: window.identity.processID,
            windows: [window],
            isProtected: false
        )
        let controller = HostController(
            capture: ProgressiveCaptureServiceFixture(
                application: application,
                visibleAfterInventoryCall: 1
            )
        )
        let now = Date()
        func context(peer: PeerIdentity, requestID: String) -> HostRequestContext {
            let connection = ConnectionRecord(
                id: UUID(),
                capabilityToken: String(repeating: "t", count: 43),
                peer: peer,
                capabilities: Set(HostCapability.allCases),
                openedAt: now,
                lastActivityAt: now,
                idleTimeout: 900
            )
            return HostRequestContext(
                requestID: requestID,
                connection: connection,
                deadline: now.addingTimeInterval(5)
            )
        }
        func expected(grantable: Bool) -> JSONValue {
            .object(["apps": .array([.object([
                "bundleId": .string(bundleIdentifier),
                "name": .string("Verified Harness"),
                "isRunning": .bool(true),
                "pid": .number(Double(window.identity.processID)),
                "windowCount": .number(1),
                "grantable": .bool(grantable),
            ])])])
        }

        let verifiedPeer = PeerIdentity(
            uid: UInt32(getuid()),
            processID: 9_001,
            name: "verified-harness",
            instanceID: "verified-harness",
            harnessProcessID: window.identity.processID,
            harnessBundleIdentifier: bundleIdentifier,
            harnessSigningIdentity: window.identity.signingIdentity,
            harnessProcessStartTimeUnixMs: window.identity.processStartTimeUnixMs,
            harnessIdentityVerified: true
        )
        let verifiedResult = try await controller.handle(
            method: "listApps",
            params: .object([:]),
            context: context(peer: verifiedPeer, requestID: "verified-harness-inventory")
        )
        #expect(verifiedResult == expected(grantable: false))

        let unverifiedResult = try await controller.handle(
            method: "listApps",
            params: .object([:]),
            context: context(
                peer: PeerIdentity(
                    uid: UInt32(getuid()),
                    processID: 9_002,
                    name: "ordinary-client",
                    instanceID: "ordinary-client"
                ),
                requestID: "ordinary-client-inventory"
            )
        )
        #expect(unverifiedResult == expected(grantable: true))
    }

    @Test func listAppsRequiresAtLeastOneIndividuallyPolicyAllowedWindow() async throws {
        let bundleIdentifier = "com.example.mixed-windows"
        let protectedWindow = try makeWindow(
            id: 7_201,
            bundle: bundleIdentifier,
            title: "Administrator Password Required"
        )
        let ordinaryWindow = try makeWindow(
            id: 7_202,
            bundle: bundleIdentifier,
            title: "Ordinary Document"
        )
        let now = Date()
        let connection = ConnectionRecord(
            id: UUID(),
            capabilityToken: String(repeating: "t", count: 43),
            peer: PeerIdentity(
                uid: UInt32(getuid()),
                processID: 9_003,
                name: "ordinary-client",
                instanceID: "ordinary-client"
            ),
            capabilities: Set(HostCapability.allCases),
            openedAt: now,
            lastActivityAt: now,
            idleTimeout: 900
        )
        let context = HostRequestContext(
            requestID: "window-policy-inventory",
            connection: connection,
            deadline: now.addingTimeInterval(5)
        )

        for (windows, expectedGrantable) in [
            ([protectedWindow], false),
            ([protectedWindow, ordinaryWindow], true),
        ] {
            let application = ApplicationDescriptor(
                bundleIdentifier: bundleIdentifier,
                name: "Mixed Windows",
                processID: protectedWindow.identity.processID,
                windows: windows,
                isProtected: false
            )
            let controller = HostController(
                capture: ProgressiveCaptureServiceFixture(
                    application: application,
                    visibleAfterInventoryCall: 1
                )
            )
            let result = try await controller.handle(
                method: "listApps",
                params: .object([:]),
                context: context
            )
            #expect(result == .object(["apps": .array([.object([
                "bundleId": .string(bundleIdentifier),
                "name": .string("Mixed Windows"),
                "isRunning": .bool(true),
                "pid": .number(Double(protectedWindow.identity.processID)),
                "windowCount": .number(Double(windows.count)),
                "grantable": .bool(expectedGrantable),
            ])])]))
        }
    }

    @Test func displayGrantIsSessionOnlyAndSupportsInteraction() async throws {
        let display = try makeDisplay()
        let store = GrantStore(idleTimeout: 900)
        let connection = UUID()
        do {
            _ = try await store.issue(
                connectionID: connection,
                scope: .display(display),
                capabilities: [.displayCapture, .syntheticInput],
                persistence: .alwaysAllowApp
            )
            Issue.record("persistent display grant was accepted")
        } catch { #expect(error as? GrantStoreError == .displayMustBeSessionOnly) }
        let receipt = try await store.issue(
            connectionID: connection,
            scope: .display(display),
            capabilities: [.displayCapture, .syntheticInput],
            persistence: .sessionOnly,
            now: Date(timeIntervalSince1970: 100)
        )
        let refreshed = try await store.authorize(
            grantID: receipt.grantID,
            connectionID: connection,
            capability: .syntheticInput,
            now: Date(timeIntervalSince1970: 500)
        )
        #expect(refreshed.expiresAt == Date(timeIntervalSince1970: 1_400))
    }

    @Test func grantOwnershipIdleExpiryAndTargetLock() async throws {
        let window = try makeWindow()
        let store = GrantStore(idleTimeout: 10)
        let owner = UUID()
        let other = UUID()
        let issued = try await store.issue(
            connectionID: owner,
            scope: .window(window.identity),
            capabilities: [.windowCapture],
            persistence: .allowOnce,
            now: Date(timeIntervalSince1970: 0)
        )
        do {
            _ = try await store.authorize(
                grantID: issued.grantID,
                connectionID: other,
                capability: .windowCapture,
                now: Date(timeIntervalSince1970: 1)
            )
            Issue.record("grant was usable by another connection")
        } catch { #expect(error as? GrantStoreError == .grantConnectionMismatch) }
        do {
            _ = try await store.authorize(
                grantID: issued.grantID,
                connectionID: owner,
                capability: .windowCapture,
                now: Date(timeIntervalSince1970: 11)
            )
            Issue.record("expired grant was accepted")
        } catch { #expect(error as? GrantStoreError == .grantExpired) }
        #expect(await store.revokeExpired(now: Date(timeIntervalSince1970: 11)).map(\.id) == [issued.grantID])

        let locks = ControllerLockStore()
        let firstGrant = UUID()
        try await locks.acquire(targetKey: "window:700", connectionID: owner, grantID: firstGrant)
        do {
            try await locks.acquire(targetKey: "window:700", connectionID: other, grantID: UUID())
            Issue.record("duplicate target lock was accepted")
        } catch { #expect(error as? GrantStoreError == .targetLocked) }
        await locks.release(grantID: firstGrant)
        try await locks.acquire(targetKey: "window:700", connectionID: other, grantID: UUID())
    }

    @Test func publicCapabilitiesAreCoherentAndObserveDoesNotTakeControllerLock() async {
        #expect(!PublicCapabilityPolicy.isCoherent([.interact]))
        #expect(!PublicCapabilityPolicy.isCoherent([.clipboardWrite]))
        #expect(!PublicCapabilityPolicy.isCoherent([.observe, .clipboardWrite]))
        #expect(PublicCapabilityPolicy.isCoherent([.observe]))
        #expect(PublicCapabilityPolicy.isCoherent([.observe, .interact, .clipboardWrite]))
        #expect(!PublicCapabilityPolicy.requiresExclusiveTargetLock([.observe]))
        #expect(PublicCapabilityPolicy.requiresExclusiveTargetLock([.observe, .interact]))

        let gate = ActionExecutionGate()
        let grant = UUID()
        #expect(await gate.acquire(grantID: grant))
        #expect(!(await gate.acquire(grantID: grant)))
        await gate.release(grantID: grant)
        #expect(await gate.acquire(grantID: grant))
    }

    @Test func frameIsCurrentOwnedIntentBoundAndSixtySeconds() async throws {
        let transform = try ScreenshotTransform(
            sourceSize: Size(width: 800, height: 600),
            outputSize: Size(width: 400, height: 300),
            globalOrigin: Point(x: -800, y: 20)
        )
        let store = FrameResourceStore()
        let grant = UUID(), connection = UUID()
        let first = await store.create(
            grantID: grant,
            connectionID: connection,
            transform: transform,
            accessibilityRevision: 7,
            now: Date(timeIntervalSince1970: 100)
        )
        #expect(first.expiresAt == Date(timeIntervalSince1970: 160))
        #expect(first.accessibilityRevision == 7)
        let validated = try await store.validate(
            frameID: first.frameID,
            grantID: grant,
            connectionID: connection,
            intent: "inspect field",
            now: Date(timeIntervalSince1970: 159)
        )
        #expect(validated.accessibilityRevision == 7)
        _ = await store.create(
            grantID: grant,
            connectionID: connection,
            transform: transform,
            now: Date(timeIntervalSince1970: 150)
        )
        do {
            _ = try await store.validate(
                frameID: first.frameID,
                grantID: grant,
                connectionID: connection,
                intent: "stale",
                now: Date(timeIntervalSince1970: 151)
            )
            Issue.record("superseded frame was accepted")
        } catch { #expect(error as? FrameResourceError == .frameNotFound) }
    }

    @Test func negativeOriginMixedScaleAffineIsExactlyInvertibleAndBoundsChecked() throws {
        let transform = try ScreenshotTransform(
            sourceSize: Size(width: 1_440, height: 900),
            outputSize: Size(width: 720, height: 300),
            globalOrigin: Point(x: -1_440, y: -50)
        )
        let image = Point(x: 333, y: 222)
        let global = try transform.globalPoint(forOutputPoint: image)
        let inverse = try transform.outputPoint(forGlobalPoint: global)
        #expect(abs(inverse.x - image.x) < 0.000_001)
        #expect(abs(inverse.y - image.y) < 0.000_001)
        #expect(transform.imageToGlobal.tx == -1_440)
        #expect(transform.imageToGlobal.m11 == 2)
        #expect(transform.imageToGlobal.m22 == 3)
        #expect(throws: ScreenshotTransformError.pointOutsideOutput) {
            try transform.globalPoint(forOutputPoint: Point(x: 720, y: 0))
        }
        #expect(WireErrorMapping.map(ScreenshotTransformError.pointOutsideOutput).code == "ELEMENT_NOT_ACTIONABLE")
    }
}

@Suite("Privacy, audit, and protected targets", .serialized)
struct PrivacyAndPolicyTests {
    @Test func windowCaptureIsReleasedOnlyAfterAnUnchangedUnprotectedPostcheck() throws {
        let policy = ProtectedProcessPolicy()
        let before = try makeWindow(title: "Ordinary document")
        #expect(try WindowCaptureReleaseGate.release(
            42,
            before: before,
            after: before,
            expectedIdentity: before.identity,
            protectedPolicy: policy
        ) == 42)

        let protected = try WindowDescriptor(
            identity: before.identity,
            title: "Administrator Password Required",
            frame: before.frame,
            layer: before.layer,
            isOnScreen: before.isOnScreen,
            isActive: before.isActive
        )
        #expect(throws: CaptureError.protectedTarget) {
            try WindowCaptureReleaseGate.release(
                42,
                before: before,
                after: protected,
                expectedIdentity: before.identity,
                protectedPolicy: policy
            )
        }

        let moved = try WindowDescriptor(
            identity: before.identity,
            title: before.title,
            frame: Rect(origin: Point(x: 121, y: 120), size: before.frame.size),
            layer: before.layer,
            isOnScreen: before.isOnScreen,
            isActive: before.isActive
        )
        #expect(throws: CaptureError.targetIdentityChanged) {
            try WindowCaptureReleaseGate.release(
                42,
                before: before,
                after: moved,
                expectedIdentity: before.identity,
                protectedPolicy: policy
            )
        }
    }

    @Test func displayCaptureAllowlistFreezesOnlyPrevalidatedIntersectingWindows() throws {
        func identity(_ windowID: UInt32, processID: Int32 = 9_000) throws -> WindowIdentity {
            try WindowIdentity(
                windowID: windowID,
                processID: processID,
                bundleIdentifier: "com.example.safe",
                ownerName: "Safe Fixture",
                signingIdentity: "safe-signing-identity",
                processStartTimeUnixMs: 1_700_000_000_000
            )
        }
        func candidate(
            _ windowID: UInt32,
            frame: Rect = Rect(origin: Point(x: 100, y: 100), size: Size(width: 300, height: 200)),
            identity candidateIdentity: WindowIdentity?,
            isOnScreen: Bool = true,
            isCurrentHost: Bool = false,
            applicationIsProtected: Bool = false,
            surfaceIsProtected: Bool = false,
            ownerHasProtectedSurface: Bool = false
        ) -> DisplayCaptureWindowCandidate {
            DisplayCaptureWindowCandidate(
                identity: candidateIdentity,
                frame: frame,
                isOnScreen: isOnScreen,
                isCurrentHost: isCurrentHost,
                applicationIsProtected: applicationIsProtected,
                surfaceIsProtected: surfaceIsProtected,
                ownerHasProtectedSurface: ownerHasProtectedSurface
            )
        }

        let safe = candidate(1_000, identity: try identity(1_000))
        let spanning = candidate(
            1_001,
            frame: Rect(origin: Point(x: 900, y: 100), size: Size(width: 300, height: 200)),
            identity: try identity(1_001)
        )
        let ownerless = candidate(1_002, identity: nil)
        let currentHost = candidate(1_003, identity: try identity(1_003), isCurrentHost: true)
        let protectedApp = candidate(
            1_004, identity: try identity(1_004), applicationIsProtected: true
        )
        let protectedWindow = candidate(
            1_005, identity: try identity(1_005), surfaceIsProtected: true
        )
        let protectedSibling = candidate(
            1_006, identity: try identity(1_006), ownerHasProtectedSurface: true
        )
        let offDisplay = candidate(
            1_007,
            frame: Rect(origin: Point(x: 1_100, y: 100), size: Size(width: 200, height: 200)),
            identity: try identity(1_007)
        )
        let hidden = candidate(1_008, identity: try identity(1_008), isOnScreen: false)
        let display = Rect(origin: Point(x: 0, y: 0), size: Size(width: 1_000, height: 800))
        let frozen = DisplayCaptureWindowAllowlistPolicy.freeze(
            candidates: [
                safe, spanning, ownerless, currentHost, protectedApp,
                protectedWindow, protectedSibling, offDisplay, hidden,
            ],
            displayFrame: display
        )
        #expect(frozen.identities.map(\.windowID) == [1_000, 1_001])

        // This protected window did not exist at inventory time. The immutable
        // SCK inclusion set cannot admit it even if it appears and disappears
        // entirely between the before/after protection snapshots.
        let transientProtected = candidate(
            1_009, identity: try identity(1_009), surfaceIsProtected: true
        )
        #expect(transientProtected.identity?.windowID == 1_009)
        #expect(!frozen.contains(windowID: 1_009))
    }

    @Test func displayCaptureWithholdsFrameWhenProtectedAppAppears() throws {
        let baseline = DisplayCaptureProtectionSnapshot(applications: [], windows: [])
        let terminal = DisplayCaptureProtectedApplicationFingerprint(
            processID: 8_001,
            bundleIdentifier: "com.apple.Terminal",
            processName: "Terminal",
            processStartTimeUnixMs: 1_700_000_000_000,
            signingIdentity: "terminal-signing-identity"
        )
        let afterLaunch = DisplayCaptureProtectionSnapshot(
            applications: [terminal],
            windows: []
        )
        #expect(throws: CaptureError.protectedTarget) {
            _ = try DisplayCaptureProtectionGate.release(
                Data("must-not-return".utf8),
                before: baseline,
                after: afterLaunch
            )
        }
    }

    @Test func displayCaptureWithholdsFrameWhenProtectedSurfaceChanges() throws {
        let application = DisplayCaptureProtectedApplicationFingerprint(
            processID: 8_002,
            bundleIdentifier: "com.apple.SecurityAgent",
            processName: "SecurityAgent",
            processStartTimeUnixMs: 1_700_000_001_000,
            signingIdentity: "security-agent-signing-identity"
        )
        let initialWindow = DisplayCaptureProtectedWindowFingerprint(
            windowID: 900,
            processID: application.processID,
            bundleIdentifier: application.bundleIdentifier,
            processName: application.processName,
            processStartTimeUnixMs: application.processStartTimeUnixMs,
            signingIdentity: application.signingIdentity,
            title: "Authentication Required",
            frame: Rect(origin: Point(x: 100, y: 100), size: Size(width: 400, height: 240)),
            layer: 20,
            isOnScreen: true
        )
        let changedWindow = DisplayCaptureProtectedWindowFingerprint(
            windowID: initialWindow.windowID,
            processID: initialWindow.processID,
            bundleIdentifier: initialWindow.bundleIdentifier,
            processName: initialWindow.processName,
            processStartTimeUnixMs: initialWindow.processStartTimeUnixMs,
            signingIdentity: initialWindow.signingIdentity,
            title: "Administrator Password Required",
            frame: Rect(origin: Point(x: 120, y: 100), size: Size(width: 400, height: 240)),
            layer: initialWindow.layer,
            isOnScreen: true
        )
        let before = DisplayCaptureProtectionSnapshot(
            applications: [application],
            windows: [initialWindow]
        )
        let restartedApplication = DisplayCaptureProtectedApplicationFingerprint(
            processID: application.processID,
            bundleIdentifier: application.bundleIdentifier,
            processName: application.processName,
            processStartTimeUnixMs: 1_700_000_002_000,
            signingIdentity: application.signingIdentity
        )
        let afterRestart = DisplayCaptureProtectionSnapshot(
            applications: [restartedApplication],
            windows: [initialWindow]
        )
        #expect(throws: CaptureError.protectedTarget) {
            _ = try DisplayCaptureProtectionGate.release(42, before: before, after: afterRestart)
        }
        let after = DisplayCaptureProtectionSnapshot(
            applications: [application],
            windows: [changedWindow]
        )
        #expect(throws: CaptureError.protectedTarget) {
            _ = try DisplayCaptureProtectionGate.release(42, before: before, after: after)
        }
        #expect(try DisplayCaptureProtectionGate.release(42, before: before, after: before) == 42)
    }

    @Test func secureSubroleRedactsAndStructuredTreeHasBoundedSymmetricLinks() throws {
        let projection = AccessibilityProjection.redactedStrings(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            title: "secret-title",
            label: "secret-label",
            value: "hunter2"
        )
        #expect(projection.secure)
        #expect(projection.title == nil)
        #expect(projection.label == nil)
        #expect(projection.value == nil)
        #expect(AccessibilityProjection.isSecure(
            role: "AXProtectedContent", subrole: nil
        ))
        #expect(AccessibilityProjection.isSecure(
            role: "AXStaticText", subrole: nil, ancestorSecure: true
        ))
        #expect(AccessibilityProjection.boundedCharacterCount(["😀"]) == 2)

        let window = try makeWindow()
        let nodes = [
            AccessibilityNodeSnapshot(
                id: 0, parentID: nil, depth: 0, role: "AXWindow", subrole: nil,
                title: "Primary", label: nil, value: nil, frame: window.frame,
                isEnabled: true, isFocused: true, isSelected: nil, secure: false,
                actions: ["AXRaise"]
            ),
            AccessibilityNodeSnapshot(
                id: 1, parentID: 0, depth: 1, role: "AXTextField", subrole: "AXSecureTextField",
                title: nil, label: nil, value: nil, frame: nil,
                isEnabled: true, isFocused: false, isSelected: nil, secure: true,
                actions: []
            ),
        ]
        let state = AccessibilityState(
            sessionID: UUID(), revision: 1, window: window, nodes: nodes, truncated: false
        )
        let json = HostController.accessibilityJSON(state, resetReason: "diff_unavailable")
        guard let object = json.objectValue,
              case .array(let encoded)? = object["nodes"],
              encoded.count == 2,
              let root = encoded[0].objectValue,
              let child = encoded[1].objectValue else {
            Issue.record("structured accessibility object was malformed")
            return
        }
        #expect(root["childElementIds"] == .array([.string("element-1")]))
        #expect(child["parentElementId"] == .string("element-0"))
        #expect(child["secure"] == .bool(true))
        #expect(child["value"] == nil)
    }

    @Test func accessibilityDiffIsDeterministicBoundedAndFrameCacheIsRevoked() async throws {
        let window = try makeWindow()
        let root = AccessibilityNodeSnapshot(
            id: 0, parentID: nil, depth: 0, role: "AXWindow", subrole: nil,
            title: "Primary", label: nil, value: nil, frame: window.frame,
            isEnabled: true, isFocused: true, isSelected: nil, secure: false,
            actions: ["AXRaise"]
        )
        let removed = AccessibilityNodeSnapshot(
            id: 2, parentID: 0, depth: 1, role: "AXButton", subrole: nil,
            title: nil, label: "Old", value: nil, frame: nil,
            isEnabled: true, isFocused: false, isSelected: nil, secure: false,
            actions: ["AXPress"]
        )
        let oldTen = AccessibilityNodeSnapshot(
            id: 10, parentID: 0, depth: 1, role: "AXStaticText", subrole: nil,
            title: nil, label: "Before", value: nil, frame: nil,
            isEnabled: true, isFocused: false, isSelected: nil, secure: false,
            actions: []
        )
        let added = AccessibilityNodeSnapshot(
            id: 1, parentID: 0, depth: 1, role: "AXButton", subrole: nil,
            title: nil, label: "New", value: nil, frame: nil,
            isEnabled: true, isFocused: false, isSelected: nil, secure: false,
            actions: ["AXPress"]
        )
        let newTen = AccessibilityNodeSnapshot(
            id: 10, parentID: 0, depth: 1, role: "AXStaticText", subrole: nil,
            title: nil, label: "After", value: nil, frame: nil,
            isEnabled: true, isFocused: false, isSelected: nil, secure: false,
            actions: []
        )
        let sessionID = UUID()
        let base = AccessibilityState(
            sessionID: sessionID, revision: 1, window: window,
            nodes: [root, removed, oldTen], truncated: false
        )
        let current = AccessibilityState(
            sessionID: sessionID, revision: 2, window: window,
            nodes: [root, added, newTen], truncated: false
        )
        let baseFrameID = UUID()
        guard let diff = HostController.accessibilityDiffJSON(
            current: current, base: base, baseFrameID: baseFrameID
        )?.objectValue,
        case .array(let upserted)? = diff["upsertedNodes"],
        case .array(let removedIDs)? = diff["removedElementIds"] else {
            Issue.record("accessibility diff was not emitted")
            return
        }
        #expect(diff["mode"] == .string("diff"))
        #expect(diff["baseFrameId"] == .string(baseFrameID.uuidString))
        #expect(upserted.compactMap { $0.objectValue?["elementId"]?.stringValue } == [
            "element-0", "element-1", "element-10",
        ])
        #expect(removedIDs == [.string("element-2")])

        let cache = AccessibilityFrameSnapshotStore(maximumEntriesPerGrant: 2)
        let grantID = UUID()
        let nextFrameID = UUID()
        let newestFrameID = UUID()
        await cache.record(grantID: grantID, frameID: baseFrameID, state: base)
        await cache.record(grantID: grantID, frameID: nextFrameID, state: current)
        await cache.record(grantID: grantID, frameID: newestFrameID, state: current)
        #expect(await cache.retainedFrameIDs(grantID: grantID) == [nextFrameID, newestFrameID])
        #expect(await cache.state(grantID: grantID, frameID: baseFrameID) == nil)
        await cache.revoke(grantID: grantID)
        #expect(await cache.retainedFrameIDs(grantID: grantID).isEmpty)

        #expect(HostController.accessibilityDiffJSON(
            current: current, base: base, baseFrameID: baseFrameID, maximumChanges: 1
        ) == nil)
    }

    @Test func auditRedactsCanariesRetainsBoundsAndRejectsUnsafeParent() throws {
        let redactor = AuditRedactor(salt: Data("salt".utf8))
        let canary = "CANARY-super-secret-window-title"
        let redacted = redactor.redact(canary)
        #expect(redacted.sha256.count == 64)
        #expect(!redacted.sha256.contains(canary))
        #expect(redacted.characterCount == canary.count)

        let connection = UUID()
        let older = AuditEvent(
            timestamp: Date(timeIntervalSince1970: 1), connectionID: connection,
            requestID: "old", action: "click", riskTier: .medium, result: .failed,
            reasonCode: "STALE_FRAME", target: nil
        )
        let newer = AuditEvent(
            timestamp: Date(timeIntervalSince1970: 100), connectionID: connection,
            requestID: "new", action: "click", riskTier: .medium, result: .allowed,
            reasonCode: nil, target: nil
        )
        let retained = AuditRetentionPolicy(maximumAge: 50, maximumEntries: 1)
            .retaining([older, newer], now: Date(timeIntervalSince1970: 110))
        #expect(retained.map(\.requestID) == ["new"])

        let root = try temporaryDirectory(mode: 0o755)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: AuditStoreError.unsafeParent) {
            try FileAuditStore(url: root.appendingPathComponent("events.jsonl"))
        }
        #expect(try fileMode(root) == 0o755)
    }

    @Test func auditFileContainsOnlyRedactedTargetMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audit/events.jsonl")
        let store = try FileAuditStore(url: url)
        let canary = "CANARY-never-write-me"
        let target = AuditTarget(
            bundleIdentifier: AuditRedactor(salt: Data("salt".utf8)).redact(canary),
            title: nil,
            windowID: 1,
            displayID: nil
        )
        try store.append(AuditEvent(
            timestamp: Date(), connectionID: UUID(), requestID: "request",
            action: "paste", riskTier: .high, result: .denied,
            reasonCode: "APPROVAL_MISMATCH", target: target
        ))
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains(canary))
        #expect(raw.contains("APPROVAL_MISMATCH"))
        #expect(try fileMode(url) == 0o600)
    }

    @Test func auditRetentionIsAppliedWhenStoreReopens() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audit/events.jsonl")
        let now = Date()
        let initial = try FileAuditStore(
            url: url,
            retention: AuditRetentionPolicy(maximumAge: 1_000, maximumEntries: 10)
        )
        try initial.append(AuditEvent(
            timestamp: now.addingTimeInterval(-100), connectionID: UUID(), requestID: "old",
            action: "click", riskTier: .medium, result: .failed,
            reasonCode: "STALE_FRAME", target: nil
        ), now: now)
        try initial.append(AuditEvent(
            timestamp: now.addingTimeInterval(-1), connectionID: UUID(), requestID: "new",
            action: "click", riskTier: .medium, result: .allowed,
            reasonCode: nil, target: nil
        ), now: now)

        let reopened = try FileAuditStore(
            url: url,
            retention: AuditRetentionPolicy(maximumAge: 50, maximumEntries: 10)
        )
        #expect(try reopened.load().map(\.requestID) == ["new"])
    }

    @Test func auditStoreRejectsPostInitializationSymlinkSubstitution() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audit/events.jsonl")
        let store = try FileAuditStore(url: url)
        let target = root.appendingPathComponent("do-not-touch")
        let canary = Data("CANARY-target-content".utf8)
        guard FileManager.default.createFile(
            atPath: target.path,
            contents: canary,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else { throw FixtureFailure.unexpected }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
        #expect(throws: AuditStoreError.unsafeFile) { try store.load() }
        #expect(throws: AuditStoreError.unsafeFile) {
            try store.append(AuditEvent(
                timestamp: Date(), connectionID: UUID(), requestID: "symlink",
                action: "click", riskTier: .medium, result: .failed,
                reasonCode: "ACCESS_DENIED", target: nil
            ))
        }
        #expect(try Data(contentsOf: target) == canary)
    }

    @Test func terminalAuthorizationAndAllSystemSettingsTargetsAreProtected() throws {
        let policy = ProtectedProcessPolicy()
        for (bundle, name) in [
            ("com.apple.Terminal", "Terminal"), ("com.googlecode.iterm2", "iTerm2"),
            ("dev.warp.Warp-Stable", "Warp"), ("com.github.wez.wezterm", "wezterm-gui"),
            ("org.alacritty", "Alacritty"), ("net.kovidgoyal.kitty", "kitty"),
            ("com.mitchellh.ghostty", "Ghostty"), ("co.zeit.hyper", "Hyper"),
            ("org.tabby", "Tabby"),
        ] {
            #expect(!policy.evaluate(bundleIdentifier: bundle, processName: name, processID: 100).allowed)
        }
        let ordinary = try makeWindow(bundle: "com.apple.systempreferences", title: "Displays")
        let privacy = try makeWindow(id: 701, bundle: "com.apple.systempreferences", title: "Privacy & Security")
        #expect(!policy.evaluate(ordinary).allowed)
        #expect(!policy.evaluate(privacy).allowed)
        #expect(policy.excludesApplicationFromDisplayCapture(
            bundleIdentifier: "com.apple.systempreferences",
            processName: "System Settings",
            processID: 100
        ))
        #expect(!policy.excludesApplicationFromDisplayCapture(
            bundleIdentifier: "com.example.safe",
            processName: "Safe App",
            processID: 101
        ))
        let authorization = try makeWindow(
            id: 702, bundle: "com.example.safe", title: "Administrator Password Required"
        )
        #expect(!policy.evaluate(authorization).allowed)
        #expect(!policy.evaluate(
            bundleIdentifier: "com.vendor.new-terminal-nightly",
            processName: "Vendor Shell",
            processID: 102
        ).allowed)
        #expect(!policy.evaluate(
            bundleIdentifier: "com.vendor.shell",
            processName: "Future Warp Preview",
            processID: 103
        ).allowed)
        #expect(RiskClassifier.classify(
            kind: .click, intent: "change system setting", key: nil, modifiers: []
        ) == .high)
    }

    @Test func elevatedProtectedOverlayBlocksBeforeNormalLayerFiltering() {
        let guarder = SyntheticDestinationGuard()
        let protectedOverlay = WindowStackEntry(
            windowID: 900, processID: 900, bundleIdentifier: "com.apple.SecurityAgent",
            processName: "SecurityAgent", title: "Authenticate", frame: Rect(
                origin: Point(x: 140, y: 140), size: Size(width: 300, height: 200)
            ), layer: 25, alpha: 1
        )
        let target = WindowStackEntry(
            windowID: 700, processID: 777, bundleIdentifier: "com.example.safe",
            processName: "Safe", frame: Rect(
                origin: Point(x: 120, y: 120), size: Size(width: 720, height: 520)
            ), layer: 0, alpha: 1
        )
        let decision = guarder.blockingOccluder(
            targetIndex: 1,
            stack: [protectedOverlay, target],
            globalPoints: [Point(x: 200, y: 200)],
            requireWholeTarget: false
        )
        #expect(decision == .protectedSurface)
        #expect(guarder.blockingProtectedOverlay(targetIndex: 1, stack: [protectedOverlay, target]))
    }

    @Test func displayInputCannotTargetTheRequestingHarnessByPointOrFocus() throws {
        let guarder = SyntheticDestinationGuard()
        let display = try makeDisplay(
            origin: Point(x: 0, y: 0),
            logical: Size(width: 1_440, height: 900),
            pixels: Size(width: 2_880, height: 1_800)
        )
        let exclusion = CaptureExcludedProcessIdentity(
            processID: 5151,
            bundleIdentifier: "com.example.fixture-harness",
            signingIdentity: "fixture-signing",
            processStartTimeUnixMs: 1_700_000_000_000
        )
        let harnessWindow = WindowStackEntry(
            windowID: 5151,
            processID: exclusion.processID,
            bundleIdentifier: exclusion.bundleIdentifier,
            processName: "Fixture Harness",
            frame: Rect(origin: Point(x: 100, y: 100), size: Size(width: 600, height: 500)),
            layer: 0,
            alpha: 1
        )
        #expect(throws: SyntheticDestinationGuardError.selfControlBlocked) {
            try guarder.validate(
                scope: .display(display),
                globalPoints: [Point(x: 200, y: 200)],
                requireWholeTarget: false,
                excludingProcess: exclusion,
                stack: [harnessWindow]
            )
        }
        #expect(throws: SyntheticDestinationGuardError.selfControlBlocked) {
            try guarder.validateFocusedApplication(
                processID: exclusion.processID,
                bundleIdentifier: exclusion.bundleIdentifier,
                excludingProcess: exclusion
            )
        }

        let safeWindow = WindowStackEntry(
            windowID: 6161,
            processID: 6161,
            bundleIdentifier: "com.example.safe",
            processName: "Safe Fixture",
            frame: harnessWindow.frame,
            layer: 0,
            alpha: 1
        )
        try guarder.validate(
            scope: .display(display),
            globalPoints: [Point(x: 200, y: 200)],
            requireWholeTarget: false,
            excludingProcess: exclusion,
            stack: [safeWindow]
        )
    }
}

@Suite("Risk, cancellation, focus, and clipboard")
struct InteractionSafetyTests {
    @Test func emergencyRiskRevocationClearsPendingAndApprovedChallenges() async {
        let store = RiskApprovalStore(challengeLifetime: 30)
        let connection = UUID()
        let approvedAuthorization = await store.authorize(
            connectionID: connection,
            requestID: "approved",
            actionDigest: "digest-approved",
            tier: .high
        )
        guard case .challenge(let approvedChallenge) = approvedAuthorization else {
            Issue.record("high-risk fixture did not create a challenge")
            return
        }
        #expect(await store.resolve(
            challengeID: approvedChallenge.id,
            connectionID: connection,
            approved: true
        ))
        _ = await store.authorize(
            connectionID: connection,
            requestID: "pending",
            actionDigest: "digest-pending",
            tier: .medium
        )
        await store.revokeAll()
        #expect((await store.pendingChallenges(connectionID: connection)).isEmpty)
        #expect(!(await store.consumeApproved(
            approvalRequestID: approvedChallenge.id,
            connectionID: connection,
            actionDigest: "digest-approved"
        )))
    }

    @Test func riskApprovalIsExactOneShotAndIntentCannotDowngradeClick() async throws {
        let store = RiskApprovalStore(challengeLifetime: 30)
        let connection = UUID()
        let authorization = await store.authorize(
            connectionID: connection,
            requestID: "request",
            actionDigest: "digest-a",
            tier: .high,
            now: Date(timeIntervalSince1970: 100)
        )
        guard case .challenge(let challenge) = authorization else {
            Issue.record("high risk did not create a challenge")
            return
        }
        #expect(await store.resolve(
            challengeID: challenge.id,
            connectionID: connection,
            approved: true,
            now: Date(timeIntervalSince1970: 101)
        ))
        #expect(!(await store.consumeApproved(
            approvalRequestID: challenge.id,
            connectionID: connection,
            actionDigest: "digest-b",
            now: Date(timeIntervalSince1970: 102)
        )))
        // A mismatch consumes the challenge, preventing later replay.
        #expect(!(await store.consumeApproved(
            approvalRequestID: challenge.id,
            connectionID: connection,
            actionDigest: "digest-a",
            now: Date(timeIntervalSince1970: 103)
        )))
        #expect(RiskClassifier.classify(
            kind: .click, intent: "inspect and view only", key: nil, modifiers: []
        ) == .medium)
        #expect(RiskClassifier.classify(
            kind: .paste, intent: "submit payment", key: nil, modifiers: []
        ) == .high)
        let expiredAuthorization = await store.authorize(
            connectionID: connection,
            requestID: "expired",
            actionDigest: "digest-expired",
            tier: .medium,
            now: Date(timeIntervalSince1970: 200)
        )
        if case .challenge(let expired) = expiredAuthorization {
            #expect(!(await store.resolve(
                challengeID: expired.id,
                connectionID: connection,
                approved: true,
                now: Date(timeIntervalSince1970: 231)
            )))
        } else { Issue.record("expected expiring challenge") }

        let nativeAuthorization = await store.authorize(
            connectionID: connection,
            requestID: "native-route",
            actionDigest: "native-digest",
            tier: .medium,
            approvalMode: .native,
            now: Date(timeIntervalSince1970: 300)
        )
        if case .challenge(let nativeChallenge) = nativeAuthorization {
            #expect(!(await store.resolve(
                challengeID: nativeChallenge.id,
                connectionID: connection,
                approved: true,
                approvalMode: .elicitation,
                now: Date(timeIntervalSince1970: 301)
            )))
        } else { Issue.record("expected native-route challenge") }
    }

    @Test func nativeActionBoundsRejectOverflowAndNegativeInputsBeforeDispatch() throws {
        let common: [String: JSONValue] = [
            "grantId": .string(UUID().uuidString),
            "frameId": .string(UUID().uuidString),
            "intent": .string("Scroll the fixture"),
            "approvalMode": .string("elicitation"),
            "timeoutMs": .number(30_000),
        ]
        var invalidScroll = common
        invalidScroll.merge([
            "kind": .string("scroll"), "direction": .string("down"),
            "amount": .number(-Double.greatestFiniteMagnitude), "unit": .string("pages"),
        ]) { _, new in new }
        let scroll = try JSONValue.object(invalidScroll).decode(HostActionRequest.self)
        #expect(throws: WireError.self) { try HostActionValidation.validate(scroll) }

        var invalidDrag = common
        invalidDrag.merge([
            "kind": .string("drag"),
            "from": .object(["kind": .string("point"), "x": .number(1), "y": .number(1)]),
            "to": .object(["kind": .string("point"), "x": .number(2), "y": .number(2)]),
            "durationMs": .number(1_000_000_000),
        ]) { _, new in new }
        let drag = try JSONValue.object(invalidDrag).decode(HostActionRequest.self)
        #expect(throws: WireError.self) { try HostActionValidation.validate(drag) }

        var invalidType = common
        invalidType.merge([
            "kind": .string("typeText"), "text": .string("x"),
            "intervalMs": .number(1_000_000_000),
        ]) { _, new in new }
        let type = try JSONValue.object(invalidType).decode(HostActionRequest.self)
        #expect(throws: WireError.self) { try HostActionValidation.validate(type) }

        var defaultedScroll = common
        defaultedScroll.merge([
            "kind": .string("scroll"), "direction": .string("down"),
        ]) { _, new in new }
        let validScroll = try JSONValue.object(defaultedScroll).decode(HostActionRequest.self)
        try HostActionValidation.validate(validScroll)
    }

    @Test func detachedCancellationCarriesAbsoluteDeadline() throws {
        let expired = DeadlineInteractionCancellation(
            base: NeverCanceled(),
            deadline: Date().addingTimeInterval(-1)
        )
        #expect(throws: InputDriverError.deadlineExceeded) { try expired.check() }
        #expect(WireErrorMapping.map(InputDriverError.deadlineExceeded).code == "ACTION_TIMEOUT")

        let relay = RelayedInteractionCancellation(base: NeverCanceled())
        relay.cancel()
        #expect(throws: InputDriverError.canceled) {
            try relay.check()
        }
    }

    @Test func scopedCancellationDoesNotCrossConnectionsOrResumeOldWork() throws {
        let token = InteractionStopToken()
        let firstConnection = UUID(), secondConnection = UUID()
        let firstGrant = UUID(), secondGrant = UUID()
        let first = token.scope(connectionID: firstConnection, grantID: firstGrant)
        let second = token.scope(connectionID: secondConnection, grantID: secondGrant)
        token.stop(grantID: firstGrant)
        #expect(throws: InputDriverError.canceled) { try first.check() }
        try second.check()
        let replacement = token.scope(connectionID: firstConnection, grantID: firstGrant)
        try replacement.check()
        token.stop(connectionID: secondConnection)
        #expect(throws: InputDriverError.canceled) { try second.check() }
        try replacement.check()
        token.stopAll()
        #expect(throws: InputDriverError.canceled) { try replacement.check() }
        try token.scope(connectionID: UUID(), grantID: UUID()).check()
    }

    @Test func deterministicDragAndTypingPlansAreBounded() throws {
        let points = try DeterministicInputPlan.dragPoints(
            from: Point(x: 0, y: 0), to: Point(x: 60, y: 30), duration: 1, hertz: 60
        )
        #expect(points.count == 61)
        #expect(points.first == Point(x: 0, y: 0))
        #expect(points.last == Point(x: 60, y: 30))
        #expect(DeterministicInputPlan.unicodeChunks(String(repeating: "a", count: 41)).map(\.count) == [20, 20, 1])
    }

    @Test func focusLeaseRestoresOnSuccessAndError() throws {
        let manager = FocusManagerFixture()
        let coordinator = FocusLeaseCoordinator(manager: manager)
        let result: Int = try coordinator.withFocus(processID: 777) { 42 }
        #expect(result == 42)
        #expect(manager.activations == [777, 100])
        manager.activations.removeAll()
        do {
            _ = try coordinator.withFocus(processID: 777) { throw FixtureFailure.expected }
            Issue.record("operation unexpectedly succeeded")
        } catch { #expect(error as? FixtureFailure == .expected) }
        #expect(manager.activations == [777, 100])
    }

    @Test func clipboardRestoresOnSuccessErrorAndDetectsExternalChange() throws {
        let fixture = PasteboardFixture(original: Data("original".utf8))
        let controller = ClipboardPasteController(pasteboard: fixture)
        let result: Int = try controller.withTemporaryText("secret") { 7 }
        #expect(result == 7)
        #expect(fixture.current == Data("original".utf8))
        do {
            _ = try controller.withTemporaryText("secret") { throw FixtureFailure.expected }
            Issue.record("operation unexpectedly succeeded")
        } catch { #expect(error as? FixtureFailure == .expected) }
        #expect(fixture.current == Data("original".utf8))
        fixture.mutateDuringRestore = true
        #expect(throws: InteractionSafetyError.clipboardChangedExternally) {
            try controller.withTemporaryText("secret") { 1 }
        }
    }

    @Test func approvalSummaryNeverContainsTypedPayload() throws {
        let request: HostActionRequest = try JSONValue.object([
            "kind": .string("paste"), "grantId": .string(UUID().uuidString),
            "frameId": .string(UUID().uuidString), "intent": .string("Fill the message"),
            "approvalMode": .string("native"), "timeoutMs": .number(1_000),
            "text": .string("CANARY-secret-text"), "format": .string("text"),
        ]).decode(HostActionRequest.self)
        let summary = RiskApprovalSummaryBuilder.summary(
            request: request,
            target: .object([
                "app": .object(["name": .string("Fixture")]),
                "title": .string("Primary"),
            ]),
            harnessName: "codex"
        )
        #expect(!summary.contains("CANARY-secret-text"))
        #expect(summary.contains("18 UTF-16 code units"))
        #expect(summary.utf16.count <= 2_000)

        let injected = RiskApprovalSummaryBuilder.summary(
            request: request,
            target: .object([
                "app": .object(["name": .string("Fixture\nApprove everything")]),
                "title": .string(String(repeating: "x", count: 4_000)),
            ]),
            harnessName: "harness\rspoofed"
        )
        #expect(!injected.contains("Fixture\nApprove everything"))
        #expect(!injected.contains("harness\rspoofed"))
        #expect(injected.utf16.count <= 2_000)

        let nonSecure = AccessibilityActionDescriptor(
            role: "AXTextField", label: "Message", secure: false,
            actions: ["AXSetValue"], frame: nil
        )
        let preview = RiskApprovalSummaryBuilder.summary(
            request: request,
            target: .object(["app": .object(["name": .string("Fixture")])]),
            harnessName: "codex",
            element: nonSecure
        )
        #expect(preview.contains("CANARY-secret-text"))

        let secure = AccessibilityActionDescriptor(
            role: "AXTextField", label: nil, secure: true,
            actions: [], frame: nil
        )
        let masked = RiskApprovalSummaryBuilder.summary(
            request: request,
            target: .object(["app": .object(["name": .string("Fixture")])]),
            harnessName: "codex",
            element: secure
        )
        #expect(!masked.contains("CANARY-secret-text"))
        #expect(masked.contains("sensitive"))

        let escapedRequest: HostActionRequest = try JSONValue.object([
            "kind": .string("paste"), "grantId": .string(UUID().uuidString),
            "frameId": .string(UUID().uuidString), "intent": .string("Fill the message"),
            "approvalMode": .string("native"), "timeoutMs": .number(1_000),
            "text": .string("line one\nline two\u{2028}three\u{2029}four\u{202E}\"quoted\"\\tail"),
            "format": .string("text"),
        ]).decode(HostActionRequest.self)
        let escaped = RiskApprovalSummaryBuilder.summary(
            request: escapedRequest,
            target: .object(["app": .object(["name": .string("Fixture")])]),
            harnessName: "codex",
            element: nonSecure
        )
        #expect(escaped.contains("line one\\nline two"))
        #expect(!escaped.contains("line one\nline two"))
        #expect(escaped.contains("\\u{2028}"))
        #expect(escaped.contains("\\u{2029}"))
        #expect(escaped.contains("\\u{202E}"))
        #expect(escaped.contains("\\\"quoted\\\""))
        #expect(escaped.contains("\\\\tail"))
        #expect(summary.contains("codex"))

        let setValue: HostActionRequest = try JSONValue.object([
            "kind": .string("setValue"), "grantId": .string(UUID().uuidString),
            "frameId": .string(UUID().uuidString), "intent": .string("Update field"),
            "approvalMode": .string("native"), "timeoutMs": .number(1_000),
            "value": .string("CANARY-value-secret"),
            "selector": .object(["kind": .string("element"), "elementId": .string("element-1")]),
        ]).decode(HostActionRequest.self)
        let setValueSummary = RiskApprovalSummaryBuilder.summary(
            request: setValue, target: .object([:]), harnessName: "cursor"
        )
        #expect(!setValueSummary.contains("CANARY-value-secret"))

        let hostileKey: HostActionRequest = try JSONValue.object([
            "kind": .string("pressKey"), "grantId": .string(UUID().uuidString),
            "frameId": .string(UUID().uuidString), "intent": .string("Use shortcut"),
            "approvalMode": .string("native"), "timeoutMs": .number(1_000),
            "key": .string("k\n\u{2028}\u{2029}\u{202E}\"\\"),
            "modifiers": .array([.string("command")]),
        ]).decode(HostActionRequest.self)
        let keySummary = RiskApprovalSummaryBuilder.summary(
            request: hostileKey, target: .object([:]), harnessName: "cursor"
        )
        #expect(keySummary.contains("k\\n\\u{2028}\\u{2029}\\u{202E}\\\"\\\\"))
        #expect(!keySummary.contains("k\n\u{2028}\u{2029}\u{202E}\"\\"))
    }

    @Test func pasteKeepsTemporaryClipboardThroughBoundedDeliveryWait() throws {
        let pasteboard = PasteboardFixture(original: Data("original".utf8))
        let input = InputFixture()
        let waiter = PasteWaiterFixture(pasteboard: pasteboard)
        let controller = TextInteractionController(
            input: input,
            clipboard: ClipboardPasteController(pasteboard: pasteboard),
            pasteWaiter: waiter,
            pasteDeliveryDelay: 0.08
        )
        try controller.paste("delivery-secret")
        #expect(waiter.observedTemporaryText == "delivery-secret")
        #expect(pasteboard.current == Data("original".utf8))
        #expect(input.keys.count == 1)
        #expect(input.keys.first?.0 == 9)
        #expect(input.keys.first?.1 == KeyboardModifier.command)
    }
}

@Suite("Indicator and native UI geometry")
struct IndicatorTests {
    @Test func nativeUIEscaperCoversSeparatorsBidiQuotesAndBackslashes() throws {
        let raw = "a\nb\u{2028}c\u{2029}d\u{202E}e\"f'\\g"
        let escaped = NativeUISanitizer.escaped(
            raw,
            maximumInputUTF16: 128,
            maximumOutputUTF16: 512
        )
        #expect(escaped == "a\\nb\\u{2028}c\\u{2029}d\\u{202E}e\\\"f\\'\\\\g")
        let forbidden: Set<UInt32> = [0x0A, 0x2028, 0x2029, 0x202E]
        #expect(!escaped.unicodeScalars.contains { forbidden.contains($0.value) })

        let bounded = NativeUISanitizer.escaped(
            String(repeating: "\u{202E}", count: 100),
            maximumInputUTF16: 100,
            maximumOutputUTF16: 31
        )
        #expect(bounded.utf16.count <= 31)
        #expect(!bounded.unicodeScalars.contains { $0.value == 0x202E })
    }

    @Test func launchAccessAndPickerTextShareTheSanitizingBoundary() throws {
        let hostile = "Visible\nInjected\u{2028}Line\u{2029}RTL\u{202E}\"quote\"\\tail"
        let expected = NativeUISanitizer.escaped(
            hostile,
            maximumInputUTF16: 512,
            maximumOutputUTF16: 1_024
        )
        let window = try makeWindow(title: hostile)
        let choice = GrantChoice(
            scope: .window(window.identity), frame: window.frame, title: hostile,
            targetMetadata: .object([:]), targetKey: "window:700",
            displayFrame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 1_000, height: 800))
        )
        #expect(AccessChoiceLabeler.labels(for: [choice]) == [expected])

        let launch = LaunchApprovalRequest(
            connectionID: UUID(),
            appName: hostile,
            bundleIdentifier: "com.example.\(hostile)",
            reason: "reason:\(hostile)",
            capabilities: [.observe]
        )
        let launchMessage = NativeAccessPromptText.launchMessage(launch)
        let launchDetails = NativeAccessPromptText.launchDetails(launch)
        #expect(!launchMessage.contains(hostile))
        #expect(launchMessage.contains("\\n"))
        #expect(launchDetails.contains("\\u{2028}"))
        #expect(launchDetails.contains("\\u{2029}"))
        #expect(launchDetails.contains("\\u{202E}"))
        #expect(launchDetails.contains("\\\"quote\\\""))
        #expect(launchDetails.contains("\\\\tail"))

        let access = AccessApprovalRequest(
            connectionID: UUID(),
            reason: "reason:\(hostile)",
            candidates: [choice],
            capabilities: [.observe],
            displayTarget: false,
            appConsentExists: false
        )
        let accessDetails = NativeAccessPromptText.accessDetails(access)
        #expect(!accessDetails.contains("reason:\(hostile)"))
        #expect(accessDetails.contains("reason:Visible\\nInjected"))
        #expect(accessDetails.contains("\\u{2028}"))
        #expect(accessDetails.contains("\\u{2029}"))
        #expect(accessDetails.contains("\\u{202E}"))
    }

    @Test func topLeftToAppKitConversionPreservesNegativeOrigins() {
        let converted = AppKitCoordinateConverter.convert(
            topLeftFrame: Rect(origin: Point(x: -1_400, y: 20), size: Size(width: 8, height: 64)),
            on: ScreenGeometry(
                quartzTopLeftFrame: Rect(origin: Point(x: -1_440, y: 0), size: Size(width: 1_440, height: 900)),
                appKitFrame: Rect(origin: Point(x: -1_440, y: 0), size: Size(width: 1_440, height: 900))
            )
        )
        #expect(converted.origin == Point(x: -1_400, y: 816))
        #expect(converted.size == Size(width: 8, height: 64))
    }

    @Test func railIsEightPointsAndOcclusionRequiresFullCoverage() {
        let placement = OverlayPlacement.leftEdge(
            targetTopLeftFrame: Rect(origin: Point(x: 2, y: 20), size: Size(width: 500, height: 400)),
            displayTopLeftFrame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 1_000, height: 800))
        )
        #expect(placement.railWidth == 8)
        let target = Rect(origin: Point(x: 0, y: 0), size: Size(width: 100, height: 100))
        #expect(!IndicatorVisibility.isFullyOccluded(
            target: target,
            by: [Rect(origin: Point(x: 0, y: 0), size: Size(width: 50, height: 100))]
        ))
        #expect(IndicatorVisibility.isFullyOccluded(
            target: target,
            by: [
                Rect(origin: Point(x: 0, y: 0), size: Size(width: 50, height: 100)),
                Rect(origin: Point(x: 50, y: 0), size: Size(width: 50, height: 100)),
            ]
        ))
    }

    @Test func duplicateWindowTitlesAreDisambiguatedAndLifecycleRevokes() throws {
        let first = try makeWindow(id: 700, title: "Duplicate")
        let second = try makeWindow(id: 701, title: "Duplicate")
        let labels = AccessChoiceLabeler.labels(for: [
            GrantChoice(
                scope: .window(first.identity), frame: first.frame, title: "Duplicate",
                targetMetadata: .object([:]), targetKey: "window:700",
                displayFrame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 1_000, height: 800))
            ),
            GrantChoice(
                scope: .window(second.identity), frame: second.frame, title: "Duplicate",
                targetMetadata: .object([:]), targetKey: "window:701",
                displayFrame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 1_000, height: 800))
            ),
        ])
        #expect(labels.count == 2)
        #expect(labels[0] != labels[1])
        #expect(labels.allSatisfy { $0.contains("Window") && $0.contains("720×520") })
        #expect(SessionLifecyclePolicy.shouldRevoke(for: NSWorkspace.sessionDidResignActiveNotification))
        #expect(SessionLifecyclePolicy.shouldRevoke(for: NSWorkspace.willSleepNotification))
        #expect(!SessionLifecyclePolicy.shouldRevoke(for: NSWorkspace.sessionDidBecomeActiveNotification))
    }
}

@Suite("Permission and public error mapping")
struct PermissionAndErrorTests {
    @Test func inputMonitoringIsOptionalButInteractiveReadinessIsNot() {
        let ready = PermissionSnapshot(
            screenCapture: .granted, accessibility: .granted,
            eventPosting: .granted, eventListening: .denied
        )
        #expect(ready.isReadyForInteractiveControl)
        #expect(ready.permits(.syntheticInput))
        let missingAX = PermissionSnapshot(
            screenCapture: .granted, accessibility: .denied,
            eventPosting: .granted, eventListening: .granted
        )
        #expect(!missingAX.isReadyForInteractiveControl)
        #expect(!missingAX.permits(.syntheticInput))
    }

    @Test func internalErrorsMapToStablePublicCodesWithoutDescriptions() {
        #expect(WireErrorMapping.map(
            WireError(code: "APP_CONTROL_DISABLED", message: "General app access is off")
        ).code == "APP_CONTROL_DISABLED")
        #expect(WireErrorMapping.map(CaptureError.permissionDenied).code == "PERMISSION_REQUIRED")
        #expect(WireErrorMapping.map(AccessibilityError.staleRevision).code == "STALE_FRAME")
        #expect(WireErrorMapping.map(InputDriverError.canceled).code == "CANCELLED")
        #expect(WireErrorMapping.map(InteractionSafetyError.focusRestoreFailed).code == "FOCUS_FAILED")
        #expect(WireErrorMapping.map(GrantStoreError.targetLocked).code == "BUSY")
        #expect(WireErrorMapping.map(SyntheticDestinationGuardError.protectedSurface).code == "ACCESS_DENIED")
        #expect(WireErrorMapping.map(FixtureFailure.unexpected).code == "INTERNAL_ERROR")
        #expect(WireErrorMapping.map(FixtureFailure.unexpected).message == "The native operation failed unexpectedly")
    }
}

private final class FocusManagerFixture: ApplicationFocusManaging, @unchecked Sendable {
    var activations: [Int32] = []
    func capture() throws -> FocusSnapshot { FocusSnapshot(processID: 100) }
    func activate(processID: Int32) -> Bool { activations.append(processID); return true }
    func restore(_ snapshot: FocusSnapshot) -> Bool { activate(processID: snapshot.processID) }
}

private final class PasteboardFixture: PasteboardAccessing, @unchecked Sendable {
    var changeCount = 1
    var current: Data
    var mutateDuringRestore = false

    init(original: Data) { self.current = original }
    func snapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(
            items: [PasteboardItemSnapshot(values: ["public.utf8-plain-text": current])],
            capturedChangeCount: changeCount
        )
    }
    func replaceWithText(_ text: String) -> Int? {
        current = Data(text.utf8)
        changeCount += 1
        return changeCount
    }
    func restore(_ snapshot: PasteboardSnapshot, ifOwnedChangeCount: Int) -> Bool {
        if mutateDuringRestore { changeCount += 1; return false }
        guard changeCount == ifOwnedChangeCount,
              let original = snapshot.items.first?.values["public.utf8-plain-text"] else { return false }
        current = original
        changeCount += 1
        return true
    }
}

private final class InputFixture: SyntheticInputDriving, @unchecked Sendable {
    var keys: [(UInt16, UInt64)] = []
    func click(globalPoint: Point, button: MouseButton, clickCount: Int, cancellation: InteractionCancellationChecking) throws {}
    func drag(from: Point, to: Point, button: MouseButton, duration: TimeInterval, cancellation: InteractionCancellationChecking) throws {}
    func typeText(_ text: String, cancellation: InteractionCancellationChecking) throws {}
    func key(code: UInt16, flags: UInt64, cancellation: InteractionCancellationChecking) throws {
        try cancellation.check()
        keys.append((code, flags))
    }
    func scroll(deltaX: Int32, deltaY: Int32, at globalPoint: Point?, cancellation: InteractionCancellationChecking) throws {}
}

private final class PasteWaiterFixture: PasteDeliveryWaiting, @unchecked Sendable {
    let pasteboard: PasteboardFixture
    var observedTemporaryText: String?
    init(pasteboard: PasteboardFixture) { self.pasteboard = pasteboard }
    func wait(duration: TimeInterval, cancellation: InteractionCancellationChecking) throws {
        try cancellation.check()
        observedTemporaryText = String(data: pasteboard.current, encoding: .utf8)
    }
}

private struct AcceptingPeerVerifierFixture: PeerCodeVerifying {
    func verify(_ peer: SocketPeerCredentials) throws {}
}

private struct RejectingPeerVerifierFixture: PeerCodeVerifying {
    func verify(_ peer: SocketPeerCredentials) throws {
        throw LocalSecurityError.signatureRejected
    }
}

private struct SocketPeerInspectorFixture: SocketPeerInspecting {
    let peer: SocketPeerCredentials
    func credentials(socket: Int32) throws -> SocketPeerCredentials { peer }
}

private final class ToggleHarnessIdentityValidatorFixture: HarnessIdentityValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Bool

    init(isCurrent: Bool) { current = isCurrent }

    func setCurrent(_ value: Bool) {
        lock.lock()
        current = value
        lock.unlock()
    }

    func isCurrent(_ peer: PeerIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

private struct EmptyCaptureServiceFixture: ScreenCaptureServing {
    func inventory() async throws -> InventorySnapshot {
        InventorySnapshot(applications: [], displays: [])
    }

    func captureWindow(
        windowID: UInt32,
        expectedIdentity: WindowIdentity,
        policy: ScreenshotSizingPolicy
    ) async throws -> ScreenshotPayload {
        throw CaptureError.windowNotFound
    }

    func captureDisplay(
        displayID: UInt32,
        policy: ScreenshotSizingPolicy,
        excludingProcess: CaptureExcludedProcessIdentity?
    ) async throws -> ScreenshotPayload {
        throw CaptureError.displayNotFound
    }
}

private actor ProgressiveCaptureServiceFixture: ScreenCaptureServing {
    private let application: ApplicationDescriptor
    private let visibleAfterInventoryCall: Int
    private var inventoryCalls = 0

    init(application: ApplicationDescriptor, visibleAfterInventoryCall: Int) {
        self.application = application
        self.visibleAfterInventoryCall = visibleAfterInventoryCall
    }

    func inventory() async throws -> InventorySnapshot {
        inventoryCalls += 1
        return InventorySnapshot(
            applications: inventoryCalls >= visibleAfterInventoryCall ? [application] : [],
            displays: [try makeDisplay()]
        )
    }

    func inventoryCallCount() -> Int { inventoryCalls }

    func captureWindow(
        windowID: UInt32,
        expectedIdentity: WindowIdentity,
        policy: ScreenshotSizingPolicy
    ) async throws -> ScreenshotPayload { throw CaptureError.captureFailed }

    func captureDisplay(
        displayID: UInt32,
        policy: ScreenshotSizingPolicy,
        excludingProcess: CaptureExcludedProcessIdentity?
    ) async throws -> ScreenshotPayload { throw CaptureError.captureFailed }
}

private struct GrantedPermissionFixture: SystemPermissionChecking {
    func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            screenCapture: .granted,
            accessibility: .granted,
            eventPosting: .granted,
            eventListening: .denied
        )
    }

    func request(_ permission: PermissionKind) -> Bool { true }
}

private final class RecordingApplicationLauncherFixture: ApplicationLaunching, @unchecked Sendable {
    var launchCount = 0

    func candidate(for selector: ApplicationSelector) -> ApplicationLaunchCandidate? {
        ApplicationLaunchCandidate(
            url: URL(fileURLWithPath: "/Applications/Absent Fixture.app"),
            bundleIdentifier: "com.example.absent",
            name: "Absent Fixture"
        )
    }

    func launch(_ candidate: ApplicationLaunchCandidate) async throws { launchCount += 1 }
}

private final class LaunchDenyingPresenterFixture: AccessApprovalPresenting, @unchecked Sendable {
    var lastLaunchRequest: LaunchApprovalRequest?

    func requestLaunchApproval(
        _ request: LaunchApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> Bool {
        lastLaunchRequest = request
        return false
    }

    func requestApproval(
        _ request: AccessApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> AccessApprovalDecision { .denied }
}

private struct LaunchAcceptingPresenterFixture: AccessApprovalPresenting {
    func requestLaunchApproval(
        _ request: LaunchApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> Bool { true }

    func requestApproval(
        _ request: AccessApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> AccessApprovalDecision {
        AccessApprovalDecision(selected: request.candidates.first, persistence: .allowOnce)
    }
}

private actor CancellationObservingPresenterFixture: AccessApprovalPresenting {
    private var presented = false
    private(set) var observedCancellation = false

    func requestApproval(
        _ request: AccessApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> AccessApprovalDecision {
        presented = true
        for _ in 0..<1_000 {
            do {
                try cancellation.check()
            } catch {
                observedCancellation = true
                return .denied
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return .denied
    }

    func waitUntilPresented() async -> Bool {
        for _ in 0..<200 {
            if presented { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return presented
    }
}

private struct FailingIndicatorFixture: ControlIndicatorPresenting {
    func show(_ state: IndicatorState) async throws { throw IndicatorPresentationError.unavailable }
    func hide(grantID: UUID) async {}
    func hide(connectionID: UUID) async {}
    func hideAll() async {}
}

private actor MaintenanceHandlerFixture: HostMethodHandling {
    var maintenanceCount = 0
    func handle(method: String, params: JSONValue?, context: HostRequestContext) async throws -> JSONValue {
        .object([:])
    }
    func disconnect(connectionID: UUID) async {}
    func emergencyStop() async {}
    func maintenance(now: Date) async { maintenanceCount += 1 }
}

private actor FixtureWireHandler: HostMethodHandling {
    var disconnectCount = 0
    func handle(method: String, params: JSONValue?, context: HostRequestContext) async throws -> JSONValue {
        switch method {
        case "requestAccess":
            return .object([
                "status": .string("granted"),
                "grantId": .string("fixture-grant-0001"),
                "target": .object([
                    "kind": .string("window"),
                    "title": .string("Computer Use MCP Fixture — Primary"),
                ]),
            ])
        case "status": return .object(["status": .string("ready")])
        default: return .object(["status": .string("completed")])
        }
    }
    func disconnect(connectionID: UUID) async { disconnectCount += 1 }
    func emergencyStop() async {}
    func maintenance(now: Date) async {}
}
