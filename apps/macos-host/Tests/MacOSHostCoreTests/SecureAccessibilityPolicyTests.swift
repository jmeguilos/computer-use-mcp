import Testing
@testable import MacOSHostCore

@Suite("Secure Accessibility value-write policy")
struct SecureAccessibilityPolicyTests {
    @Test func onlyAnExplicitlyApprovedDirectSecureTextFieldCanBeWritten() {
        for (role, subrole) in [
            ("AXSecureTextField", nil),
            ("AXTextField", "AXSecureTextField"),
        ] {
            #expect(AccessibilityProjection.isDirectSecureTextField(
                role: role,
                subrole: subrole
            ))
            #expect(!AccessibilitySecureElementPolicy.allowsValueWrite(
                role: role,
                subrole: subrole,
                secureAncestorOrAmbiguity: false,
                authorization: .ordinary
            ))
            #expect(AccessibilitySecureElementPolicy.allowsValueWrite(
                role: role,
                subrole: subrole,
                secureAncestorOrAmbiguity: false,
                authorization: .approvedDirectSecure
            ))
        }

        #expect(AccessibilitySecureElementPolicy.allowsValueWrite(
            role: "AXTextField",
            subrole: nil,
            secureAncestorOrAmbiguity: false,
            authorization: .ordinary
        ))
        #expect(!AccessibilitySecureElementPolicy.allowsValueWrite(
            role: "AXTextField",
            subrole: nil,
            secureAncestorOrAmbiguity: false,
            authorization: .approvedDirectSecure
        ))
    }

    @Test func protectedContentAndSecureOrAmbiguousAncestryStayDeniedAfterApproval() {
        for (role, subrole) in [
            ("AXProtectedContent", nil),
            ("AXGroup", "AXProtectedContent"),
        ] {
            #expect(AccessibilityProjection.isProtectedContent(role: role, subrole: subrole))
            for authorization in [
                AccessibilityValueWriteAuthorization.ordinary,
                .approvedDirectSecure,
            ] {
                #expect(!AccessibilitySecureElementPolicy.allowsValueWrite(
                    role: role,
                    subrole: subrole,
                    secureAncestorOrAmbiguity: false,
                    authorization: authorization
                ))
            }
        }

        for (role, subrole) in [
            ("AXSecureTextField", nil),
            ("AXTextField", "AXSecureTextField"),
            ("AXTextField", nil),
        ] {
            for authorization in [
                AccessibilityValueWriteAuthorization.ordinary,
                .approvedDirectSecure,
            ] {
                #expect(!AccessibilitySecureElementPolicy.allowsValueWrite(
                    role: role,
                    subrole: subrole,
                    secureAncestorOrAmbiguity: true,
                    authorization: authorization
                ))
            }
        }
    }

    @Test func secureValueProjectionAndSelectionRemainUnavailable() {
        let canary = "CANARY-secure-value"
        let projection = AccessibilityProjection.redactedStrings(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            title: canary + "-title",
            label: canary + "-label",
            value: canary
        )

        #expect(projection.secure)
        #expect(projection.title == nil)
        #expect(projection.label == nil)
        #expect(projection.value == nil)

        let selectionError = WireErrorMapping.map(AccessibilityError.secureElement)
        #expect(selectionError.code == "ACCESS_DENIED")
        #expect(selectionError.message.contains("only an exact approved value write"))
    }
}
