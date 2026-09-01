import Foundation
import Testing
@testable import MacOSHostCore

@Suite("Frame-bound semantic risk classification")
struct SemanticRiskClassifierTests {
    @Test func resolvedControlSemanticsOverrideBenignCallerIntent() throws {
        let request = try action(
            .click,
            intent: "Inspect this harmless control",
            fields: ["selector": elementSelector]
        )
        let cases: [AccessibilityActionDescriptor] = [
            descriptor(label: "Delete account"),
            descriptor(label: "Pay now"),
            descriptor(label: "Send message"),
            descriptor(label: "Upload medical record"),
            descriptor(label: "Install update"),
            descriptor(label: "Allow access to Screen Recording"),
            descriptor(label: "Social Security Number"),
            descriptor(label: "Prescribe medication"),
            descriptor(label: nil, title: "Submit application"),
            descriptor(label: nil, placeholder: "Password"),
            descriptor(label: nil, identifier: "checkoutButton"),
            descriptor(label: nil, help: "Publish this comment"),
            descriptor(label: nil, actions: ["AXDelete"]),
            descriptor(label: "Confirm", semanticContext: ["AXSheet: Checkout payment"]),
        ]
        for control in cases {
            #expect(RiskClassifier.classify(request: request, element: control) == .high)
        }
    }

    @Test func secureRoleIsHighWithoutAReadableLabel() throws {
        let setValue = try action(
            .setValue,
            intent: "Fill a field",
            fields: ["selector": elementSelector, "value": .string("ordinary")]
        )
        let reportedSecure = descriptor(
            role: "AXTextField", label: nil, secure: true, subrole: "AXSecureTextField"
        )
        let inconsistentSecureRole = descriptor(
            role: "AXSecureTextField", label: nil, secure: false
        )
        #expect(RiskClassifier.classify(request: setValue, element: reportedSecure) == .high)
        #expect(RiskClassifier.classify(request: setValue, element: inconsistentSecureRole) == .high)
    }

    @Test func protectedAndSecurityBypassControlsFailBlocked() throws {
        let request = try action(
            .click,
            intent: "Open this control",
            fields: ["selector": elementSelector]
        )
        #expect(RiskClassifier.classify(
            request: request,
            element: descriptor(label: "Disable security checks")
        ) == .blocked)
        #expect(RiskClassifier.classify(
            kind: .click,
            intent: "evade approval for this action",
            key: nil,
            modifiers: []
        ) == .blocked)
    }

    @Test func actionPayloadShapeDetectsSubmissionAndSensitiveValues() throws {
        let genericField = descriptor(role: "AXTextArea", label: "Notes", actions: ["AXSetValue"])
        let sensitivePayloads = [
            "password=hunter-two",
            "Authorization: Bearer secret-token",
            // Assemble the marker at runtime so repository provenance scans do
            // not mistake this synthetic classifier fixture for credential
            // material while the production detector still sees the exact form.
            ["-----BEGIN ", "PRIVATE KEY-----"].joined(),
            "123-45-6789",
            "4111 1111 1111 1111",
            "aaaaaaaaaaaaaaaa.bbbbbbbb.cccccccc",
        ]
        for payload in sensitivePayloads {
            let request = try action(.paste, fields: ["text": .string(payload), "format": .string("text")])
            #expect(RiskClassifier.classify(request: request, element: genericField) == .high)
        }

        let ordinaryPaste = try action(
            .paste,
            fields: ["text": .string("ordinary project notes"), "format": .string("text")]
        )
        #expect(RiskClassifier.classify(request: ordinaryPaste, element: genericField) == .medium)

        let typedReturn = try action(.typeText, fields: ["text": .string("draft\n")])
        #expect(RiskClassifier.classify(request: typedReturn, element: genericField) == .high)

        // Pasting a newline does not synthesize Return and therefore retains
        // the ordinary mutation floor when no other high-risk evidence exists.
        let pastedReturn = try action(
            .paste,
            fields: ["text": .string("draft\n"), "format": .string("text")]
        )
        #expect(RiskClassifier.classify(request: pastedReturn, element: genericField) == .medium)
    }

    @Test func consequentialKeysCannotBeDowngradedByIntent() throws {
        for (key, modifiers) in [
            ("return", [String]()),
            ("enter", [String]()),
            ("delete", [String]()),
            ("w", ["command"]),
            ("q", ["command"]),
        ] {
            let request = try action(
                .pressKey,
                intent: "Navigate only",
                fields: [
                    "key": .string(key),
                    "modifiers": .array(modifiers.map(JSONValue.string)),
                ]
            )
            #expect(RiskClassifier.classify(request: request, element: nil) == .high)
        }
        let arrow = try action(
            .pressKey,
            fields: ["key": .string("down"), "modifiers": .array([])]
        )
        #expect(RiskClassifier.classify(request: arrow, element: nil) == .low)
    }

    @Test func onlyNarrowProvenAXOperationsSkipApproval() throws {
        let selection = try action(
            .selectText,
            fields: ["selector": elementSelector, "text": .string("word")]
        )
        #expect(RiskClassifier.classify(
            request: selection,
            element: descriptor(role: "AXTextArea", label: "Notes", actions: ["AXSetValue"])
        ) == .low)
        #expect(RiskClassifier.classify(request: selection, element: nil) == .medium)
        #expect(RiskClassifier.classify(
            request: selection,
            element: descriptor(role: "AXSecureTextField", label: nil, secure: true)
        ) == .high)

        let disclosureClick = try action(
            .click,
            fields: ["selector": elementSelector]
        )
        #expect(RiskClassifier.classify(
            request: disclosureClick,
            element: descriptor(role: "AXDisclosureTriangle", label: "Details"),
            elementEnabled: true
        ) == .low)
        #expect(RiskClassifier.classify(
            request: disclosureClick,
            element: descriptor(role: "AXDisclosureTriangle", label: "Delete details")
        ) == .high)
        #expect(RiskClassifier.classify(
            request: disclosureClick,
            element: descriptor(role: "AXButton", label: "Details")
        ) == .medium)

        let showMenu = try action(
            .performSecondaryAction,
            fields: ["selector": elementSelector, "action": .string("AXShowMenu")]
        )
        #expect(RiskClassifier.classify(
            request: showMenu,
            element: descriptor(role: "AXPopUpButton", label: "View", actions: ["AXShowMenu"])
        ) == .low)
        #expect(RiskClassifier.classify(request: showMenu, element: nil) == .medium)

        let deleteAction = try action(
            .performSecondaryAction,
            fields: ["selector": elementSelector, "action": .string("AXDelete")]
        )
        #expect(RiskClassifier.classify(
            request: deleteAction,
            element: descriptor(role: "AXRow", label: "Item", actions: ["AXDelete"])
        ) == .high)
    }

    @Test func onlyCurrentFrameEnabledSingleLeftAXPressClicksSkipApproval() throws {
        let singleLeft = try action(
            .click,
            fields: ["selector": elementSelector]
        )
        let identifiedPress = descriptor(
            role: "AXButton",
            label: "Run harmless action",
            actions: ["AXPress"],
            identifier: "fixture.run"
        )
        #expect(RiskClassifier.classify(
            request: singleLeft,
            element: identifiedPress,
            elementEnabled: true
        ) == .low)
        #expect(RiskClassifier.classify(
            request: singleLeft,
            element: identifiedPress,
            elementEnabled: false
        ) == .medium)
        #expect(RiskClassifier.classify(
            request: singleLeft,
            element: identifiedPress,
            elementEnabled: nil
        ) == .medium)

        let rightClick = try action(
            .click,
            fields: [
                "selector": elementSelector,
                "mouseButton": .string("right"),
            ]
        )
        #expect(RiskClassifier.classify(
            request: rightClick,
            element: identifiedPress,
            elementEnabled: true
        ) == .medium)

        let doubleClick = try action(
            .click,
            fields: [
                "selector": elementSelector,
                "clickCount": .number(2),
            ]
        )
        #expect(RiskClassifier.classify(
            request: doubleClick,
            element: identifiedPress,
            elementEnabled: true
        ) == .medium)

        let coordinate = try action(
            .click,
            fields: [
                "selector": .object([
                    "kind": .string("point"), "x": .number(10), "y": .number(20),
                ]),
            ]
        )
        #expect(RiskClassifier.classify(
            request: coordinate,
            element: identifiedPress,
            elementEnabled: true
        ) == .medium)
        #expect(RiskClassifier.classify(
            request: singleLeft,
            element: descriptor(role: "AXButton", label: nil, actions: ["AXPress"]),
            elementEnabled: true
        ) == .medium)
        #expect(RiskClassifier.classify(
            request: singleLeft,
            element: descriptor(role: "AXButton", label: "Open", actions: ["AXShowMenu"]),
            elementEnabled: true
        ) == .medium)
        #expect(RiskClassifier.classify(
            request: singleLeft,
            element: descriptor(
                role: "AXButton",
                label: "Confirm",
                actions: ["AXPress"],
                identifier: "generic.confirm"
            ),
            elementEnabled: true
        ) == .medium)
        #expect(RiskClassifier.classify(
            request: singleLeft,
            element: nil,
            elementEnabled: true
        ) == .medium)

        #expect(RiskClassifier.classify(
            request: singleLeft,
            element: descriptor(role: "AXButton", label: "Delete account", actions: ["AXPress"]),
            elementEnabled: true
        ) == .high)
    }

    @Test func usernameLabelAloneIsNotCredentialContext() throws {
        let username = try action(
            .setValue,
            intent: "Update the synthetic username field",
            fields: ["selector": elementSelector, "value": .string("Grace Hopper")]
        )
        let ordinaryUsername = descriptor(
            role: "AXTextField",
            label: "Username",
            actions: ["AXSetValue"],
            identifier: "fixture.username"
        )
        #expect(RiskClassifier.classify(
            request: username,
            element: ordinaryUsername
        ) == .medium)

        for credentialControl in [
            descriptor(role: "AXTextField", label: "Password", actions: ["AXSetValue"]),
            descriptor(role: "AXTextField", label: "Passcode", actions: ["AXSetValue"]),
            descriptor(role: "AXTextField", label: "OTP", actions: ["AXSetValue"]),
            descriptor(role: "AXTextField", label: "Credential", actions: ["AXSetValue"]),
            descriptor(
                role: "AXTextField", label: "Username", actions: ["AXSetValue"],
                semanticContext: ["AXGroup: Login"]
            ),
            descriptor(
                role: "AXTextField", label: "Username", actions: ["AXSetValue"],
                identifier: "auth.username"
            ),
        ] {
            #expect(RiskClassifier.classify(request: username, element: credentialControl) == .high)
        }

        #expect(RiskClassifier.classify(
            request: username,
            element: descriptor(
                role: "AXSecureTextField", label: nil, secure: true, actions: []
            )
        ) == .high)
    }

    @Test func enabledIdentifiedOrdinaryTextMutationsSkipApproval() throws {
        for role in ["AXTextField", "AXTextArea"] {
            let field = descriptor(
                role: role,
                label: "Profile detail",
                actions: ["AXSetValue"],
                identifier: "fixture.profile-detail"
            )
            for kind in [HostActionKind.setValue, .typeText, .paste] {
                let request = try textMutation(kind, payload: "ordinary fixture text")
                #expect(RiskClassifier.classify(
                    request: request,
                    element: field,
                    elementEnabled: true
                ) == .low)
            }
        }
    }

    @Test func textMutationFastPathRequiresCurrentEnabledIdentifiedTarget() throws {
        let field = descriptor(
            role: "AXTextField",
            label: "Display name",
            actions: ["AXSetValue"],
            identifier: "fixture.display-name"
        )
        let unidentified = descriptor(
            role: "AXTextField",
            label: nil,
            actions: ["AXSetValue"]
        )

        for kind in [HostActionKind.setValue, .typeText, .paste] {
            let request = try textMutation(kind, payload: "ordinary fixture text")
            #expect(RiskClassifier.classify(
                request: request,
                element: field,
                elementEnabled: false
            ) == .medium)
            // nil is the fail-closed result for a missing frame, no focused
            // text node, or more than one focused node in the current frame.
            #expect(RiskClassifier.classify(
                request: request,
                element: field,
                elementEnabled: nil
            ) == .medium)
            #expect(RiskClassifier.classify(
                request: request,
                element: unidentified,
                elementEnabled: true
            ) == .medium)
        }

        let setValue = try textMutation(.setValue, payload: "ordinary fixture text")
        #expect(RiskClassifier.classify(
            request: setValue,
            element: descriptor(
                role: "AXTextField",
                label: "Display name",
                actions: [],
                identifier: "fixture.display-name"
            ),
            elementEnabled: true
        ) == .low)
        #expect(RiskClassifier.classify(
            request: setValue,
            element: descriptor(
                role: "AXTextField",
                label: "Value",
                actions: ["AXSetValue"],
                identifier: "generic.value"
            ),
            elementEnabled: true
        ) == .medium)
    }

    @Test func secureCredentialAndSensitiveTextMutationsRemainHighRisk() throws {
        let ordinaryField = descriptor(
            role: "AXTextField",
            label: "Profile detail",
            actions: ["AXSetValue"],
            identifier: "fixture.profile-detail"
        )
        let secureField = descriptor(
            role: "AXTextField",
            label: nil,
            secure: true,
            actions: ["AXSetValue"],
            subrole: "AXSecureTextField"
        )
        let credentialField = descriptor(
            role: "AXTextField",
            label: "Password",
            actions: ["AXSetValue"],
            identifier: "fixture.password"
        )

        for kind in [HostActionKind.setValue, .typeText, .paste] {
            let ordinary = try textMutation(kind, payload: "ordinary fixture text")
            #expect(RiskClassifier.classify(
                request: ordinary,
                element: secureField,
                elementEnabled: true
            ) == .high)
            #expect(RiskClassifier.classify(
                request: ordinary,
                element: credentialField,
                elementEnabled: true
            ) == .high)

            let sensitive = try textMutation(kind, payload: "password=fixture-only")
            #expect(RiskClassifier.classify(
                request: sensitive,
                element: ordinaryField,
                elementEnabled: true
            ) == .high)
        }

        for payload in ["draft\n", "draft\r"] {
            let request = try textMutation(.typeText, payload: payload)
            #expect(RiskClassifier.classify(
                request: request,
                element: ordinaryField,
                elementEnabled: true
            ) == .high)
        }
    }

    @Test func unmodifiedNavigationKeysAreLowButModifiedAndConsequentialKeysAreNot() throws {
        let unmodifiedNavigationKeys = [
            "tab", "escape", "esc", "up", "down", "left", "right",
            "arrow_up", "arrow_down", "arrow_left", "arrow_right",
            "pageup", "pagedown", "page_up", "page_down", "home", "end",
        ]
        for key in unmodifiedNavigationKeys {
            let request = try action(
                .pressKey,
                fields: ["key": .string(key), "modifiers": .array([])]
            )
            #expect(RiskClassifier.classify(request: request, element: nil) == .low)
        }

        for (key, modifiers) in [
            ("tab", ["shift"]),
            ("left", ["option"]),
            ("arrow_right", ["command"]),
        ] {
            let request = try action(
                .pressKey,
                fields: [
                    "key": .string(key),
                    "modifiers": .array(modifiers.map(JSONValue.string)),
                ]
            )
            #expect(RiskClassifier.classify(request: request, element: nil) == .medium)
        }

        for (key, modifiers) in [
            ("return", [String]()),
            ("delete", [String]()),
            ("w", ["command"]),
            ("q", ["command"]),
        ] {
            let request = try action(
                .pressKey,
                fields: [
                    "key": .string(key),
                    "modifiers": .array(modifiers.map(JSONValue.string)),
                ]
            )
            #expect(RiskClassifier.classify(request: request, element: nil) == .high)
        }
    }

    @Test func enabledEvidenceIsReadFromTheExactFrame() async throws {
        let store = AccessibilityFrameSnapshotStore(maximumEntriesPerGrant: 2)
        let grantID = UUID()
        let enabledFrameID = UUID()
        let disabledFrameID = UUID()
        let field = descriptor(
            role: "AXTextArea",
            label: "Notes",
            actions: ["AXSetValue"],
            identifier: "fixture.notes"
        )
        let request = try textMutation(.typeText, payload: "ordinary fixture text")

        await store.record(
            grantID: grantID,
            frameID: enabledFrameID,
            state: try accessibilityState(revision: 1, enabled: true)
        )
        await store.record(
            grantID: grantID,
            frameID: disabledFrameID,
            state: try accessibilityState(revision: 2, enabled: false)
        )

        let enabled = await store.state(grantID: grantID, frameID: enabledFrameID)?
            .nodes.first(where: { $0.id == 1 })?.isEnabled
        let disabled = await store.state(grantID: grantID, frameID: disabledFrameID)?
            .nodes.first(where: { $0.id == 1 })?.isEnabled
        let missing = await store.state(grantID: grantID, frameID: UUID())?
            .nodes.first(where: { $0.id == 1 })?.isEnabled

        #expect(RiskClassifier.classify(
            request: request, element: field, elementEnabled: enabled
        ) == .low)
        #expect(RiskClassifier.classify(
            request: request, element: field, elementEnabled: disabled
        ) == .medium)
        #expect(RiskClassifier.classify(
            request: request, element: field, elementEnabled: missing
        ) == .medium)
    }

    @Test func coordinateAndAmbiguousActionsKeepConservativeFloor() throws {
        let coordinate = try action(
            .click,
            fields: [
                "selector": .object([
                    "kind": .string("point"), "x": .number(10), "y": .number(20),
                ]),
            ]
        )
        #expect(RiskClassifier.classify(request: coordinate, element: nil) == .medium)

        let ordinarySetValue = try action(
            .setValue,
            fields: ["selector": elementSelector, "value": .string("Taylor")]
        )
        #expect(RiskClassifier.classify(
            request: ordinarySetValue,
            element: descriptor(role: "AXTextField", label: "Display name", actions: ["AXSetValue"])
        ) == .medium)
        #expect(RiskClassifier.classify(
            kind: .typeText,
            intent: "Enter postal code and keep the sidebar visible",
            key: nil,
            modifiers: []
        ) == .medium)
        #expect(RiskClassifier.classify(
            kind: .typeText,
            intent: "Enter the account PIN",
            key: nil,
            modifiers: []
        ) == .high)
    }

    @Test func approvalBindingDetectsSemanticControlChanges() {
        let original = AccessibilityActionDescriptor(
            role: "AXButton",
            label: "Send",
            secure: false,
            actions: ["AXPress", "AXShowMenu"],
            frame: Rect(origin: Point(x: 10, y: 10), size: Size(width: 80, height: 24)),
            identifier: "message.send"
        )
        let moved = AccessibilityActionDescriptor(
            role: "AXButton",
            label: "Send",
            secure: false,
            actions: ["AXShowMenu", "AXPress"],
            frame: Rect(origin: Point(x: 200, y: 300), size: Size(width: 80, height: 24)),
            identifier: "message.send"
        )
        #expect(original.hasSameControlSemantics(as: moved))
        #expect(!original.hasSameControlSemantics(as: descriptor(
            role: "AXButton", label: "Delete", actions: ["AXPress", "AXShowMenu"],
            identifier: "message.send"
        )))
        #expect(!original.hasSameControlSemantics(as: descriptor(
            role: "AXButton", label: "Send", secure: true,
            actions: ["AXPress", "AXShowMenu"], identifier: "message.send"
        )))
        #expect(!original.hasSameControlSemantics(as: descriptor(
            role: "AXButton", label: "Send", actions: ["AXPress"], identifier: "message.send"
        )))
        #expect(!original.hasSameControlSemantics(as: descriptor(
            role: "AXButton", label: "Send", actions: ["AXPress", "AXShowMenu"],
            identifier: "message.send", semanticContext: ["AXSheet: Delete account"]
        )))
    }

    @Test func scrollingRemainsSafeUnlessIndependentEvidenceIsConsequential() throws {
        let ordinary = try action(
            .scroll,
            fields: ["direction": .string("down"), "amount": .number(1), "unit": .string("pages")]
        )
        #expect(RiskClassifier.classify(request: ordinary, element: nil) == .low)

        let consequential = try action(
            .scroll,
            intent: "Review before submitting payment",
            fields: ["direction": .string("down"), "amount": .number(1), "unit": .string("pages")]
        )
        #expect(RiskClassifier.classify(request: consequential, element: nil) == .high)
    }

    private var elementSelector: JSONValue {
        .object(["kind": .string("element"), "elementId": .string("element-1")])
    }

    private func action(
        _ kind: HostActionKind,
        intent: String = "Perform the requested fixture action",
        fields: [String: JSONValue] = [:]
    ) throws -> HostActionRequest {
        var object: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "grantId": .string(UUID().uuidString),
            "frameId": .string(UUID().uuidString),
            "intent": .string(intent),
            "approvalMode": .string("elicitation"),
            "timeoutMs": .number(1_000),
        ]
        object.merge(fields) { _, new in new }
        let request = try JSONValue.object(object).decode(HostActionRequest.self)
        try HostActionValidation.validate(request)
        return request
    }

    private func textMutation(
        _ kind: HostActionKind,
        payload: String
    ) throws -> HostActionRequest {
        switch kind {
        case .setValue:
            return try action(
                kind,
                fields: ["selector": elementSelector, "value": .string(payload)]
            )
        case .typeText:
            return try action(kind, fields: ["text": .string(payload)])
        case .paste:
            return try action(
                kind,
                fields: ["text": .string(payload), "format": .string("text")]
            )
        default:
            preconditionFailure("textMutation supports only text-mutating actions")
        }
    }

    private func accessibilityState(
        revision: UInt64,
        enabled: Bool
    ) throws -> AccessibilityState {
        let identity = try WindowIdentity(
            windowID: 700,
            processID: 777,
            bundleIdentifier: "com.jmeguilos.computer-use-mcp.fixture",
            ownerName: "Computer Use MCP Fixture",
            signingIdentity: String(repeating: "a", count: 64),
            processStartTimeUnixMs: 1_700_000_000_000
        )
        let window = try WindowDescriptor(
            identity: identity,
            title: "Computer Use MCP Fixture",
            frame: Rect(
                origin: Point(x: 120, y: 120),
                size: Size(width: 720, height: 520)
            ),
            layer: 0,
            isOnScreen: true,
            isActive: true
        )
        let node = AccessibilityNodeSnapshot(
            id: 1,
            parentID: nil,
            depth: 0,
            role: "AXTextArea",
            subrole: nil,
            title: nil,
            label: "Notes",
            value: nil,
            frame: nil,
            isEnabled: enabled,
            isFocused: true,
            isSelected: nil,
            secure: false,
            actions: ["AXSetValue"]
        )
        return AccessibilityState(
            sessionID: UUID(),
            revision: revision,
            window: window,
            nodes: [node],
            truncated: false
        )
    }

    private func descriptor(
        role: String = "AXButton",
        label: String?,
        secure: Bool = false,
        actions: [String] = ["AXPress"],
        subrole: String? = nil,
        title: String? = nil,
        identifier: String? = nil,
        help: String? = nil,
        placeholder: String? = nil,
        semanticContext: [String] = []
    ) -> AccessibilityActionDescriptor {
        AccessibilityActionDescriptor(
            role: role,
            label: label,
            secure: secure,
            actions: actions,
            frame: nil,
            subrole: subrole,
            title: title,
            identifier: identifier,
            help: help,
            placeholder: placeholder,
            semanticContext: semanticContext
        )
    }
}
