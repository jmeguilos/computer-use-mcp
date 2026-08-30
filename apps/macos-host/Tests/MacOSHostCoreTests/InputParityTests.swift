import Foundation
import Testing
@testable import MacOSHostCore

@Suite("Public input parity")
struct InputParityTests {
    @Test func syntheticInputAndClipboardLeaseIsGlobalAcrossGrants() async {
        let gate = ActionExecutionGate()
        let first = UUID()
        let second = UUID()
        #expect(await gate.acquire(grantID: first, requiresGlobalSyntheticInput: true))
        #expect(await gate.hasActiveSyntheticInput())
        #expect(!(await gate.acquire(grantID: second, requiresGlobalSyntheticInput: true)))
        #expect(!(await gate.acquire(grantID: second)))
        await gate.release(grantID: first)
        #expect(!(await gate.hasActiveSyntheticInput()))
        #expect(await gate.acquire(grantID: second, requiresGlobalSyntheticInput: true))
        await gate.release(grantID: second)
    }

    @Test func namedKeyVocabularyHasExactNativeMappings() throws {
        let expected: Set<String> = [
            "return", "enter", "tab", "space", "backspace", "delete",
            "forward_delete", "forwarddelete", "escape", "esc", "clear",
            "help", "insert", "home", "end", "page_up", "pageup",
            "page_down", "pagedown", "left", "arrow_left", "right",
            "arrow_right", "up", "arrow_up", "down", "arrow_down",
            "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9",
            "f10", "f11", "f12", "f13", "f14", "f15", "f16", "f17",
            "f18", "f19", "f20",
        ]
        #expect(Set(PublicKeyMap.namedKeyCodes.keys) == expected)
        #expect(PublicKeyMap.code(for: "backspace") == 51)
        #expect(PublicKeyMap.code(for: "forward_delete") == 117)
        #expect(PublicKeyMap.code(for: "arrow_left") == 123)
        #expect(PublicKeyMap.code(for: "f1") == 122)
        #expect(PublicKeyMap.code(for: "f12") == 111)
        #expect(PublicKeyMap.code(for: "f20") == 90)
        #expect(PublicKeyMap.code(for: "z") != nil)
        #expect(PublicKeyMap.code(for: "Z") == nil)
        #expect(PublicKeyMap.code(for: "f21") == nil)
        #expect(PublicKeyMap.code(for: "ENTER") == nil)
        #expect(PublicKeyMap.code(for: "😀") == nil)

        for key in expected {
            try HostActionValidation.validate(try pressKeyRequest(key))
        }
        do {
            try HostActionValidation.validate(try pressKeyRequest("volume_up"))
            Issue.record("An unadvertised named key passed native validation")
        } catch {
            #expect((error as? WireError)?.code == "invalid_action")
        }
    }

    @Test func elementFallbackIsNarrowAndApprovalBound() {
        #expect(ElementClickFallbackPolicy.canUseAXPress(mouseButton: "left", clickCount: 1))
        #expect(!ElementClickFallbackPolicy.canUseAXPress(mouseButton: "right", clickCount: 1))
        #expect(!ElementClickFallbackPolicy.canUseAXPress(mouseButton: "left", clickCount: 2))
        #expect(ElementClickFallbackPolicy.permitsFallback(after: .actionUnsupported))
        #expect(!ElementClickFallbackPolicy.permitsFallback(after: .operationFailed))
        #expect(!ElementClickFallbackPolicy.permitsFallback(after: .staleRevision))

        let bounds = Rect(
            origin: Point(x: 100, y: 100),
            size: Size(width: 720, height: 520)
        )
        let approved = descriptor(
            frame: Rect(
                origin: Point(x: 120, y: 140),
                size: Size(width: 80, height: 40)
            ),
            actions: ["AXShowMenu", "AXPress"],
            semanticContext: ["AXWindow:Settings", "AXGroup:Privacy"]
        )
        let reordered = descriptor(
            frame: approved.frame,
            actions: ["AXPress", "AXShowMenu"],
            semanticContext: approved.semanticContext
        )
        #expect(ElementClickFallbackPolicy.isSameBoundTarget(reordered, as: approved))
        #expect(ElementClickFallbackPolicy.center(of: reordered, within: bounds) == Point(x: 160, y: 160))

        let changedContext = descriptor(
            frame: approved.frame,
            actions: approved.actions,
            semanticContext: ["AXWindow:Settings", "AXGroup:Accounts"]
        )
        #expect(!ElementClickFallbackPolicy.isSameBoundTarget(changedContext, as: approved))
        let moved = descriptor(
            frame: Rect(
                origin: Point(x: 121, y: 140),
                size: Size(width: 80, height: 40)
            ),
            actions: approved.actions,
            semanticContext: approved.semanticContext
        )
        #expect(!ElementClickFallbackPolicy.isSameBoundTarget(moved, as: approved))

        let secure = AccessibilityActionDescriptor(
            role: "AXTextField",
            label: nil,
            secure: true,
            actions: [],
            frame: approved.frame,
            subrole: "AXSecureTextField",
            semanticContext: approved.semanticContext
        )
        #expect(ElementClickFallbackPolicy.center(of: secure, within: bounds) == nil)
        let outside = descriptor(
            frame: Rect(
                origin: Point(x: 900, y: 900),
                size: Size(width: 80, height: 40)
            ),
            actions: [],
            semanticContext: approved.semanticContext
        )
        #expect(ElementClickFallbackPolicy.center(of: outside, within: bounds) == nil)
    }

    @Test func dragRunnerValidatesImmediatelyBeforeEveryPostedEvent() throws {
        let start = Point(x: 10, y: 20)
        let middle = Point(x: 20, y: 30)
        let end = Point(x: 30, y: 40)
        let fixture = DragRunnerFixture()

        try DeterministicDragRunner.run(
            points: [start, middle, end],
            duration: 0,
            cancellation: NeverCanceled(),
            validateDestination: fixture.validate
        ) { kind, point in
            try fixture.emit(kind, at: point)
        }

        #expect(fixture.trace == [
            .validate(start), .emit(.down, start),
            .validate(middle), .emit(.move, middle),
            .validate(end), .emit(.move, end),
            .validate(end), .emit(.up, end),
        ])
    }

    @Test func dragRunnerAbortsOnLiveDestinationChangeAndBalancesMouseUp() throws {
        let start = Point(x: 10, y: 20)
        let acceptedMove = Point(x: 20, y: 30)
        let blockedMove = Point(x: 30, y: 40)
        let fixture = DragRunnerFixture(failOnValidationNumber: 3)

        do {
            try DeterministicDragRunner.run(
                points: [start, acceptedMove, blockedMove],
                duration: 0,
                cancellation: NeverCanceled(),
                validateDestination: fixture.validate
            ) { kind, point in
                try fixture.emit(kind, at: point)
            }
            Issue.record("Drag unexpectedly continued into a changed destination")
        } catch {
            #expect(error as? SyntheticDestinationGuardError == .unrelatedOccluder)
        }

        #expect(fixture.trace == [
            .validate(start), .emit(.down, start),
            .validate(acceptedMove), .emit(.move, acceptedMove),
            .validate(blockedMove),
            .emit(.up, acceptedMove),
        ])
    }

    @Test func dragRunnerCancellationAfterMouseDownStillBalancesMouseUp() throws {
        let start = Point(x: 10, y: 20)
        let acceptedMove = Point(x: 20, y: 30)
        let canceledMove = Point(x: 30, y: 40)
        let fixture = DragRunnerFixture()
        let cancellation = ToggleCancellationFixture()

        do {
            try DeterministicDragRunner.run(
                points: [start, acceptedMove, canceledMove],
                duration: 0,
                cancellation: cancellation,
                validateDestination: fixture.validate
            ) { kind, point in
                try fixture.emit(kind, at: point)
                if kind == .move { cancellation.cancel() }
            }
            Issue.record("Canceled drag unexpectedly completed")
        } catch {
            #expect(error as? InputDriverError == .canceled)
        }

        #expect(fixture.trace == [
            .validate(start), .emit(.down, start),
            .validate(acceptedMove), .emit(.move, acceptedMove),
            .emit(.up, acceptedMove),
        ])
    }

    private func pressKeyRequest(_ key: String) throws -> HostActionRequest {
        try JSONValue.object([
            "kind": .string("pressKey"),
            "grantId": .string(UUID().uuidString),
            "frameId": .string(UUID().uuidString),
            "intent": .string("Exercise a documented keyboard key"),
            "timeoutMs": .number(30_000),
            "approvalMode": .string("native"),
            "key": .string(key),
            "modifiers": .array([]),
        ]).decode(HostActionRequest.self)
    }

    private func descriptor(
        frame: Rect?,
        actions: [String],
        semanticContext: [String]
    ) -> AccessibilityActionDescriptor {
        AccessibilityActionDescriptor(
            role: "AXButton",
            label: "Continue",
            secure: false,
            actions: actions,
            frame: frame,
            identifier: "continue-button",
            semanticContext: semanticContext
        )
    }
}

private enum DragTraceEntry: Equatable {
    case validate(Point)
    case emit(SyntheticDragEventKind, Point)
}

private final class DragRunnerFixture: @unchecked Sendable {
    private let failOnValidationNumber: Int?
    private var validationCount = 0
    var trace: [DragTraceEntry] = []

    init(failOnValidationNumber: Int? = nil) {
        self.failOnValidationNumber = failOnValidationNumber
    }

    func validate(_ point: Point) throws {
        validationCount += 1
        trace.append(.validate(point))
        if validationCount == failOnValidationNumber {
            throw SyntheticDestinationGuardError.unrelatedOccluder
        }
    }

    func emit(_ kind: SyntheticDragEventKind, at point: Point) throws {
        trace.append(.emit(kind, point))
    }
}

private final class ToggleCancellationFixture: InteractionCancellationChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false

    func cancel() {
        lock.withLock { canceled = true }
    }

    func check() throws {
        if lock.withLock({ canceled }) { throw InputDriverError.canceled }
    }
}
