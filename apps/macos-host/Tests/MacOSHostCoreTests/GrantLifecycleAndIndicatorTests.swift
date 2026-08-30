import Darwin
import Foundation
import Testing
@testable import MacOSHostCore

@Suite("Exact-window lifecycle maintenance")
struct GrantLifecycleMaintenanceTests {
    @Test func hiddenWindowRemainsGrantedUntilTheExactIdentityDisappears() async throws {
        let visible = try lifecycleWindow(isOnScreen: true)
        let capture = MutableLifecycleCapture(window: visible)
        let indicator = LifecycleIndicatorFixture()
        let accessibility = LifecycleAccessibilityFixture()
        let controller = HostController(
            capture: capture,
            accessibility: accessibility,
            permissions: LifecyclePermissionFixture(),
            accessPresenter: LifecycleAccessPresenterFixture(),
            indicator: indicator
        )
        let connection = lifecycleConnection()
        let response = try await controller.handle(
            method: "requestAccess",
            params: lifecycleAccessRequest(),
            context: lifecycleContext(connection: connection)
        )
        let grantID = try #require(response.objectValue?["grantId"]?.stringValue.flatMap(UUID.init(uuidString:)))

        let hidden = try lifecycleWindow(identity: visible.identity, isOnScreen: false)
        await capture.setWindow(hidden)
        await controller.maintenance()
        #expect(await controller.activeGrantCount() == 1)
        #expect(!(await indicator.hiddenGrantIDs()).contains(grantID))

        await capture.setWindow(nil)
        await controller.maintenance()
        #expect(await controller.activeGrantCount() == 0)
        #expect((await indicator.hiddenGrantIDs()).contains(grantID))
    }

    @Test func reusedNumericWindowIDRevokesTheOriginalGrant() async throws {
        let original = try lifecycleWindow(isOnScreen: true)
        let capture = MutableLifecycleCapture(window: original)
        let indicator = LifecycleIndicatorFixture()
        let accessibility = LifecycleAccessibilityFixture()
        let controller = HostController(
            capture: capture,
            accessibility: accessibility,
            permissions: LifecyclePermissionFixture(),
            accessPresenter: LifecycleAccessPresenterFixture(),
            indicator: indicator
        )
        let connection = lifecycleConnection()
        let response = try await controller.handle(
            method: "requestAccess",
            params: lifecycleAccessRequest(),
            context: lifecycleContext(connection: connection)
        )
        let grantID = try #require(response.objectValue?["grantId"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let replacementIdentity = try WindowIdentity(
            windowID: original.identity.windowID,
            processID: original.identity.processID,
            bundleIdentifier: original.identity.bundleIdentifier,
            ownerName: original.identity.ownerName,
            signingIdentity: original.identity.signingIdentity,
            processStartTimeUnixMs: original.identity.processStartTimeUnixMs + 1
        )
        await capture.setWindow(try lifecycleWindow(identity: replacementIdentity, isOnScreen: true))

        await controller.maintenance()

        #expect(await controller.activeGrantCount() == 0)
        #expect((await indicator.hiddenGrantIDs()).contains(grantID))
    }

    @Test func sameMetadataAXWindowRecreationRevokesTheOriginalGrant() async throws {
        let original = try lifecycleWindow(isOnScreen: true)
        let capture = MutableLifecycleCapture(window: original)
        let indicator = LifecycleIndicatorFixture()
        let accessibility = LifecycleAccessibilityFixture()
        let controller = HostController(
            capture: capture,
            accessibility: accessibility,
            permissions: LifecyclePermissionFixture(),
            accessPresenter: LifecycleAccessPresenterFixture(),
            indicator: indicator
        )
        let response = try await controller.handle(
            method: "requestAccess",
            params: lifecycleAccessRequest(),
            context: lifecycleContext(connection: lifecycleConnection())
        )
        let grantID = try #require(
            response.objectValue?["grantId"]?.stringValue.flatMap(UUID.init(uuidString:))
        )

        await accessibility.simulateWindowRecreation()
        await controller.maintenance()

        #expect(await controller.activeGrantCount() == 0)
        #expect((await indicator.hiddenGrantIDs()).contains(grantID))
    }

    @Test func transientInventoryFailureIsNotTreatedAsAClosedWindow() async throws {
        let capture = MutableLifecycleCapture(window: try lifecycleWindow(isOnScreen: true))
        let accessibility = LifecycleAccessibilityFixture()
        let controller = HostController(
            capture: capture,
            accessibility: accessibility,
            permissions: LifecyclePermissionFixture(),
            accessPresenter: LifecycleAccessPresenterFixture(),
            indicator: LifecycleIndicatorFixture()
        )
        let connection = lifecycleConnection()
        _ = try await controller.handle(
            method: "requestAccess",
            params: lifecycleAccessRequest(),
            context: lifecycleContext(connection: connection)
        )
        await capture.setInventoryFailure(true)

        await controller.maintenance()

        #expect(await controller.activeGrantCount() == 1)
    }

    @Test func unpluggedDisplayRevokesItsSessionGrantAndRail() async throws {
        let capture = MutableLifecycleCapture(window: nil)
        let indicator = LifecycleIndicatorFixture()
        let controller = HostController(
            capture: capture,
            permissions: LifecyclePermissionFixture(),
            accessPresenter: LifecycleAccessPresenterFixture(),
            indicator: indicator
        )
        let connection = lifecycleConnection()
        let response = try await controller.handle(
            method: "requestAccess",
            params: lifecycleDisplayAccessRequest(),
            context: lifecycleContext(connection: connection)
        )
        let grantID = try #require(
            response.objectValue?["grantId"]?.stringValue.flatMap(UUID.init(uuidString:))
        )

        await capture.setDisplay(nil)
        await controller.maintenance()

        #expect(await controller.activeGrantCount() == 0)
        #expect((await indicator.hiddenGrantIDs()).contains(grantID))
    }

    @Test func reconfiguredDisplayIDCannotInheritTheOriginalGrant() async throws {
        let capture = MutableLifecycleCapture(window: nil)
        let indicator = LifecycleIndicatorFixture()
        let controller = HostController(
            capture: capture,
            permissions: LifecyclePermissionFixture(),
            accessPresenter: LifecycleAccessPresenterFixture(),
            indicator: indicator
        )
        let connection = lifecycleConnection()
        let response = try await controller.handle(
            method: "requestAccess",
            params: lifecycleDisplayAccessRequest(),
            context: lifecycleContext(connection: connection)
        )
        let grantID = try #require(
            response.objectValue?["grantId"]?.stringValue.flatMap(UUID.init(uuidString:))
        )
        await capture.setDisplay(try lifecycleDisplay(
            frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 1_920, height: 1_080)),
            pixelSize: Size(width: 3_840, height: 2_160)
        ))

        await controller.maintenance()

        #expect(await controller.activeGrantCount() == 0)
        #expect((await indicator.hiddenGrantIDs()).contains(grantID))
    }
}

@Suite("Indicator attachment safety")
struct IndicatorAttachmentSafetyTests {
    private let target = Rect(
        origin: Point(x: 120, y: 120),
        size: Size(width: 720, height: 520)
    )

    @Test func anyPartialOverlapOfTheAttachmentStripDetachesTheRail() throws {
        let strip = try #require(IndicatorVisibility.attachmentStrip(target: target))
        #expect(strip.cgRect.maxX == target.cgRect.minX)
        let onePointOverlap = Rect(
            origin: Point(x: strip.cgRect.maxX - 1, y: strip.cgRect.midY),
            size: Size(width: 20, height: 1)
        )

        #expect(!IndicatorVisibility.canAttachRail(
            target: target,
            isOnScreen: true,
            occluders: [onePointOverlap]
        ))
    }

    @Test func anyTargetOcclusionDetachesBeforeExpansionCanCoverTheForegroundWindow() {
        let partialOccluder = Rect(
            origin: Point(x: 400, y: 300),
            size: Size(width: 80, height: 80)
        )

        #expect(!IndicatorVisibility.canAttachRail(
            target: target,
            isOnScreen: true,
            occluders: [partialOccluder]
        ))
    }

    @Test func nonoverlappingForegroundWindowsDoNotDetachAnOtherwiseVisibleTarget() {
        let remoteWindow = Rect(
            origin: Point(x: 1_000, y: 300),
            size: Size(width: 80, height: 80)
        )

        #expect(IndicatorVisibility.canAttachRail(
            target: target,
            isOnScreen: true,
            occluders: [remoteWindow]
        ))
    }

    @Test func hiddenOrFullyCoveredTargetUsesTheDetachedStatusPanel() {
        #expect(!IndicatorVisibility.canAttachRail(
            target: target,
            isOnScreen: false,
            occluders: []
        ))
        #expect(!IndicatorVisibility.canAttachRail(
            target: target,
            isOnScreen: true,
            occluders: [target]
        ))
    }

    @Test func attachedRailIgnoresGlobalDetachedSlotAllocation() throws {
        let first = try #require(IndicatorVisibility.attachmentStrip(target: target, slot: 0))
        let later = try #require(IndicatorVisibility.attachmentStrip(target: target, slot: 12))
        #expect(first == later)

        let display = Rect(
            origin: Point(x: 0, y: 0),
            size: Size(width: 1_440, height: 900)
        )
        let firstPanel = try #require(IndicatorVisibility.panelFrame(
            target: target,
            display: display,
            targetAttached: true,
            slot: 0,
            expanded: false
        ))
        let laterPanel = try #require(IndicatorVisibility.panelFrame(
            target: target,
            display: display,
            targetAttached: true,
            slot: 12,
            expanded: false
        ))
        #expect(firstPanel == laterPanel)
    }

    @Test func detachedSlotsFailClosedInsteadOfClampingAndPiling() throws {
        let shortDisplay = Rect(
            origin: Point(x: 0, y: 0),
            size: Size(width: 1_440, height: 160)
        )
        let first = try #require(IndicatorVisibility.panelFrame(
            target: target,
            display: shortDisplay,
            targetAttached: false,
            slot: 0,
            expanded: false
        ))
        let second = try #require(IndicatorVisibility.panelFrame(
            target: target,
            display: shortDisplay,
            targetAttached: false,
            slot: 1,
            expanded: false
        ))
        #expect(first != second)
        #expect(IndicatorVisibility.panelFrame(
            target: target,
            display: shortDisplay,
            targetAttached: false,
            slot: 2,
            expanded: false
        ) == nil)
    }

    @Test func lowerStackWindowOccupyingOutsideStripAlsoDetaches() throws {
        let strip = try #require(IndicatorVisibility.attachmentStrip(target: target))
        #expect(!IndicatorVisibility.canAttachRail(
            target: target,
            isOnScreen: true,
            occluders: [],
            attachmentOccupants: [strip]
        ))
    }
}

private enum LifecycleFixtureError: Error {
    case inventoryUnavailable
    case captureUnsupported
}

private actor MutableLifecycleCapture: ScreenCaptureServing {
    private var window: WindowDescriptor?
    private var display: DisplayIdentity?
    private var inventoryFails = false

    init(window: WindowDescriptor?) {
        self.window = window
        display = try? lifecycleDisplay()
    }

    func setWindow(_ window: WindowDescriptor?) {
        self.window = window
    }

    func setInventoryFailure(_ value: Bool) {
        inventoryFails = value
    }

    func setDisplay(_ display: DisplayIdentity?) {
        self.display = display
    }

    func inventory() async throws -> InventorySnapshot {
        guard !inventoryFails else { throw LifecycleFixtureError.inventoryUnavailable }
        let applications = window.map { window in
            [ApplicationDescriptor(
                bundleIdentifier: window.identity.bundleIdentifier,
                name: window.identity.ownerName,
                processID: window.identity.processID,
                windows: [window],
                isProtected: false
            )]
        } ?? []
        return InventorySnapshot(
            applications: applications,
            displays: display.map { [$0] } ?? []
        )
    }

    func captureWindow(
        windowID: UInt32,
        expectedIdentity: WindowIdentity,
        policy: ScreenshotSizingPolicy
    ) async throws -> ScreenshotPayload {
        throw LifecycleFixtureError.captureUnsupported
    }

    func captureDisplay(
        displayID: UInt32,
        policy: ScreenshotSizingPolicy,
        excludingProcess: CaptureExcludedProcessIdentity?
    ) async throws -> ScreenshotPayload {
        throw LifecycleFixtureError.captureUnsupported
    }
}

private actor LifecycleAccessibilityFixture: AccessibilityServing {
    private var generation = 0
    private var bindingGenerations: [ObjectIdentifier: Int] = [:]
    private var sessions: [UUID: (identity: WindowIdentity, generation: Int)] = [:]

    func simulateWindowRecreation() { generation += 1 }

    func createWindowBinding(window: WindowDescriptor) throws -> AccessibilityWindowBinding {
        let binding = AccessibilityWindowBinding.fixtureToken()
        bindingGenerations[ObjectIdentifier(binding)] = generation
        return binding
    }

    func validateWindowBinding(
        _ binding: AccessibilityWindowBinding,
        window: WindowDescriptor
    ) throws {
        guard bindingGenerations[ObjectIdentifier(binding)] == generation else {
            throw AccessibilityError.windowNotFound
        }
    }

    func openWindowSession(
        sessionID: UUID,
        binding: AccessibilityWindowBinding,
        window: WindowDescriptor
    ) throws {
        try validateWindowBinding(binding, window: window)
        sessions[sessionID] = (window.identity, generation)
    }

    func validateWindowBinding(sessionID: UUID, window: WindowDescriptor) throws {
        guard let session = sessions[sessionID],
              session.identity == window.identity,
              session.generation == generation else {
            throw AccessibilityError.windowNotFound
        }
    }

    func refreshWindowBinding(sessionID: UUID, window: WindowDescriptor) throws -> UInt64 {
        try validateWindowBinding(sessionID: sessionID, window: window)
        return 1
    }

    func state(
        sessionID: UUID,
        window: WindowDescriptor,
        maximumNodes: Int,
        maximumDepth: Int,
        maximumCharacters: Int
    ) throws -> AccessibilityState {
        throw AccessibilityError.operationFailed
    }

    func perform(
        sessionID: UUID,
        revision: UInt64,
        command: AccessibilityCommand,
        cancellation: any InteractionCancellationChecking
    ) throws { throw AccessibilityError.operationFailed }

    func validateFocusedWindow(sessionID: UUID, revision: UInt64) throws {
        throw AccessibilityError.operationFailed
    }

    func describeActionTarget(
        sessionID: UUID,
        revision: UInt64,
        nodeID: Int
    ) throws -> AccessibilityActionDescriptor { throw AccessibilityError.operationFailed }

    func describeFocusedActionTarget(
        sessionID: UUID,
        revision: UInt64
    ) throws -> AccessibilityActionDescriptor { throw AccessibilityError.operationFailed }

    func raise(
        window: WindowDescriptor,
        cancellation: any InteractionCancellationChecking
    ) async throws { throw AccessibilityError.operationFailed }

    func selectText(
        sessionID: UUID,
        revision: UInt64,
        nodeID: Int,
        text: String,
        prefix: String?,
        suffix: String?,
        selectionType: String,
        cancellation: any InteractionCancellationChecking
    ) throws { throw AccessibilityError.operationFailed }

    func close(sessionID: UUID) { sessions.removeValue(forKey: sessionID) }
}

private actor LifecycleIndicatorFixture: ControlIndicatorPresenting {
    private var hidden: Set<UUID> = []

    func show(_ state: IndicatorState) async throws {}
    func hide(grantID: UUID) async { hidden.insert(grantID) }
    func hide(connectionID: UUID) async {}
    func hideAll() async {}
    func hiddenGrantIDs() -> Set<UUID> { hidden }
}

private struct LifecyclePermissionFixture: SystemPermissionChecking {
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

private struct LifecycleAccessPresenterFixture: AccessApprovalPresenting {
    func requestLaunchApproval(
        _ request: LaunchApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> Bool { false }

    func requestApproval(
        _ request: AccessApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> AccessApprovalDecision {
        AccessApprovalDecision(selected: request.candidates.first, persistence: .allowOnce)
    }
}

private func lifecycleWindow(
    identity: WindowIdentity? = nil,
    isOnScreen: Bool
) throws -> WindowDescriptor {
    let identity = try identity ?? WindowIdentity(
        windowID: 8_001,
        processID: 8_001,
        bundleIdentifier: "com.example.lifecycle-fixture",
        ownerName: "Lifecycle Fixture",
        signingIdentity: String(repeating: "b", count: 64),
        processStartTimeUnixMs: 1_700_000_000_000
    )
    return try WindowDescriptor(
        identity: identity,
        title: "Lifecycle Fixture Window",
        frame: Rect(origin: Point(x: 120, y: 120), size: Size(width: 720, height: 520)),
        layer: 0,
        isOnScreen: isOnScreen,
        isActive: isOnScreen
    )
}

private func lifecycleDisplay(
    frame: Rect = Rect(origin: Point(x: 0, y: 0), size: Size(width: 1_440, height: 900)),
    pixelSize: Size = Size(width: 2_880, height: 1_800)
) throws -> DisplayIdentity {
    try DisplayIdentity(
        displayID: 42,
        frame: frame,
        logicalSize: frame.size,
        pixelSize: pixelSize,
        pointPixelScaleX: pixelSize.width / frame.size.width,
        pointPixelScaleY: pixelSize.height / frame.size.height,
        name: "Fixture Display"
    )
}

private func lifecycleConnection() -> ConnectionRecord {
    let now = Date()
    return ConnectionRecord(
        id: UUID(),
        capabilityToken: String(repeating: "t", count: 43),
        peer: PeerIdentity(
            uid: UInt32(getuid()),
            processID: 9_001,
            name: "lifecycle-test-harness",
            instanceID: "lifecycle-test",
            harnessProcessID: 9_101,
            harnessBundleIdentifier: "com.example.lifecycle-test-harness",
            harnessSigningIdentity: String(repeating: "f", count: 64),
            harnessProcessStartTimeUnixMs: 1_700_000_001_000,
            harnessIdentityVerified: true
        ),
        capabilities: Set(HostCapability.allCases),
        openedAt: now,
        lastActivityAt: now,
        idleTimeout: 900
    )
}

private func lifecycleContext(connection: ConnectionRecord) -> HostRequestContext {
    HostRequestContext(
        requestID: UUID().uuidString,
        connection: connection,
        deadline: Date().addingTimeInterval(10)
    )
}

private func lifecycleAccessRequest() -> JSONValue {
    .object([
        "target": .object([
            "kind": .string("window"),
            "app": .object([
                "kind": .string("bundle_id"),
                "value": .string("com.example.lifecycle-fixture"),
            ]),
            "launchIfNeeded": .bool(false),
        ]),
        "reason": .string("Test exact-window lifecycle maintenance"),
        "capabilities": .array([.string("observe")]),
        "timeoutMs": .number(5_000),
    ])
}

private func lifecycleDisplayAccessRequest() -> JSONValue {
    .object([
        "target": .object([
            "kind": .string("display"),
            "displayId": .string("display-42"),
        ]),
        "reason": .string("Test exact-display lifecycle maintenance"),
        "capabilities": .array([.string("observe")]),
        "timeoutMs": .number(5_000),
    ])
}
