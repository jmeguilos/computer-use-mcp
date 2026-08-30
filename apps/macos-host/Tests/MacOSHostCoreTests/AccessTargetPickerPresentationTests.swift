import Foundation
import Testing
@testable import MacOSHostCore

@Suite("Metadata-only access target picker presentation")
struct AccessTargetPickerPresentationTests {
    private let displayFrame = Rect(
        origin: Point(x: -1_440, y: 0),
        size: Size(width: 1_440, height: 900)
    )

    private func windowChoice(
        id: UInt32,
        title: String,
        x: Double,
        bundleIdentifier: String = "com.example.fixture",
        processID: Int32 = 4_242,
        signingIdentity: String = "designated-requirement-digest"
    ) throws -> GrantChoice {
        let identity = try WindowIdentity(
            windowID: id,
            processID: processID,
            bundleIdentifier: bundleIdentifier,
            ownerName: "Fixture",
            signingIdentity: signingIdentity,
            processStartTimeUnixMs: 1_700_000_000_000
        )
        return GrantChoice(
            scope: .window(identity),
            frame: Rect(origin: Point(x: x, y: 40), size: Size(width: 720, height: 520)),
            title: title,
            targetMetadata: .object([
                "kind": .string("window"),
                "displayId": .string("display-a1b2"),
            ]),
            targetKey: "window:\(id)",
            displayFrame: displayFrame
        )
    }

    @Test func pickerViewportKeepsAlertControlsReachableOnShortDisplays() {
        #expect(AccessTargetPickerLayout.viewportHeight(
            contentHeight: 596,
            visibleScreenHeight: 720
        ) == 480)
        #expect(AccessTargetPickerLayout.viewportHeight(
            contentHeight: 596,
            visibleScreenHeight: 650
        ) == 410)
        #expect(AccessTargetPickerLayout.viewportHeight(
            contentHeight: 420,
            visibleScreenHeight: 1_080
        ) == 420)
    }

    @Test func duplicateTitlesRemainExactAndVisiblyDistinguishableWithoutPreviews() throws {
        let request = AccessApprovalRequest(
            connectionID: UUID(),
            requesterName: "Fixture harness",
            applicationName: "Two Window Fixture",
            bundleIdentifier: "com.example.fixture",
            reason: "Choose the editor window",
            candidates: [
                try windowChoice(id: 700, title: "Document", x: -1_320),
                try windowChoice(id: 701, title: "Document", x: -580),
            ],
            capabilities: [.observe, .interact],
            displayTarget: false,
            appConsentExists: false
        )

        let presentation = AccessTargetPickerPresentation.make(request)
        #expect(presentation.previewPolicy == .metadataOnly)
        #expect(presentation.choices.count == 2)
        #expect(presentation.choices.map(\.kind) == [.window, .window])
        #expect(presentation.choices.map(\.title) == ["Document", "Document"])
        #expect(presentation.choices[0].identifier == "Window 1 of 2 • Window ID 700")
        #expect(presentation.choices[1].identifier == "Window 2 of 2 • Window ID 701")
        #expect(presentation.choices[0].bounds == "720 × 520 pt at (-1320, 40)")
        #expect(presentation.choices[0].displayContext.contains("display-a1b2"))
        #expect(presentation.choices[0].displayContext.contains("-1440"))
        #expect(presentation.selectionSummary(at: 1) ==
            "Selected exact window • Window 2 of 2 • Window ID 701 • title: Document")
        #expect(presentation.selectionSummary(at: -1) == nil)
        #expect(presentation.selectionSummary(at: 2) == nil)
        #expect(presentation.verifiedIconIdentity?.processID == 4_242)
        #expect(presentation.capabilityLabels == ["Interact", "View"])
        #expect(!presentation.isSessionOnly)
        #expect(presentation.canRememberApplication)
    }

    @Test func inconsistentProcessIdentityNeverQualifiesForVerifiedIconResolution() throws {
        let request = AccessApprovalRequest(
            connectionID: UUID(),
            applicationName: "Fixture",
            bundleIdentifier: "com.example.fixture",
            reason: "Inspect metadata",
            candidates: [
                try windowChoice(id: 700, title: "One", x: 0),
                try windowChoice(id: 701, title: "Two", x: 100, processID: 4_243),
            ],
            capabilities: [.observe],
            displayTarget: false,
            appConsentExists: true
        )

        let presentation = AccessTargetPickerPresentation.make(request)
        #expect(presentation.previewPolicy == .metadataOnly)
        #expect(presentation.verifiedIconIdentity == nil)
        #expect(presentation.applicationAlreadyRemembered)
        #expect(!presentation.canRememberApplication)
        #expect(presentation.persistenceExplanation.contains("exact window"))
    }

    @Test func displayChoiceIsExplicitlySessionOnlyAndShowsDisplayContext() throws {
        let display = try DisplayIdentity(
            displayID: 88,
            frame: displayFrame,
            logicalSize: Size(width: 1_440, height: 900),
            pixelSize: Size(width: 2_880, height: 1_800),
            pointPixelScale: 2,
            name: "Side Display",
            isMain: false,
            isMirrored: true
        )
        let choice = GrantChoice(
            scope: .display(display),
            frame: display.frame,
            title: display.name,
            targetMetadata: .object(["kind": .string("display")]),
            targetKey: "display:88",
            displayFrame: display.frame
        )
        let request = AccessApprovalRequest(
            connectionID: UUID(),
            requesterName: "Harness\nForged label",
            reason: "Observe\nall windows",
            candidates: [choice],
            capabilities: [.observe],
            displayTarget: true,
            appConsentExists: false
        )

        let presentation = AccessTargetPickerPresentation.make(request)
        #expect(presentation.previewPolicy == .metadataOnly)
        #expect(presentation.isSessionOnly)
        #expect(!presentation.canRememberApplication)
        #expect(presentation.choices[0].kind == .display)
        #expect(presentation.choices[0].identifier == "Display ID 88")
        #expect(presentation.choices[0].displayContext ==
            "Secondary display • Mirrored • 2880 × 1800 px • 2× scale")
        #expect(presentation.persistenceExplanation ==
            "Session only. Display approval is never remembered.")
        #expect(presentation.requester == "Harness\\nForged label")
        #expect(presentation.reason == "Observe\\nall windows")
        #expect(presentation.verifiedIconIdentity == nil)
    }
}
