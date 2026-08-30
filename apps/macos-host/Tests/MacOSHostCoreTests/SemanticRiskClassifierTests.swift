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
        #expect(RiskClassifier.classify(request: arrow, element: nil) == .medium)
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
            element: descriptor(role: "AXDisclosureTriangle", label: "Details")
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
            intent: "Enter postal code and pin the sidebar",
            key: nil,
            modifiers: []
        ) == .medium)
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
