import Foundation
import Testing
@testable import MacOSHostCore

@Suite("Harness process ancestry")
struct HarnessIdentityResolverTests {
    @Test func accessoryHelperCannotShadowRegularMainApplication() throws {
        let inspector = HarnessAncestryFixture(
            parents: [100: 200, 200: 300, 300: 400, 400: 1],
            applications: [
                200: application(
                    name: "Cursor Helper: mcp-process",
                    bundleIdentifier: "com.example.cursor.helper",
                    activationPolicy: .accessory
                ),
                300: application(
                    name: "Cursor",
                    bundleIdentifier: "com.example.cursor",
                    signingIdentity: "regular-signing",
                    processStartTimeUnixMs: 1_700_000_003_000,
                    activationPolicy: .regular
                ),
                400: application(
                    name: "Outer Launcher",
                    bundleIdentifier: "com.example.outer-launcher",
                    activationPolicy: .regular
                ),
            ]
        )

        let resolved = try #require(HarnessProcessIdentityResolver.resolve(
            startingAt: 100,
            inspector: inspector
        ))
        #expect(resolved == HarnessProcessIdentity(
            name: "Cursor",
            processID: 300,
            bundleIdentifier: "com.example.cursor",
            signingIdentity: "regular-signing",
            processStartTimeUnixMs: 1_700_000_003_000
        ))
    }

    @Test func accessoryOnlyAncestryFailsClosed() {
        let inspector = HarnessAncestryFixture(
            parents: [100: 200, 200: 1],
            applications: [
                200: application(
                    name: "Menu Helper",
                    bundleIdentifier: "com.example.menu-helper",
                    activationPolicy: .accessory
                ),
            ]
        )

        #expect(HarnessProcessIdentityResolver.resolve(
            startingAt: 100,
            inspector: inspector
        ) == nil)
    }

    @Test func invalidNearestRegularMetadataFailsClosedBeforeOuterLauncher() {
        let invalidCandidates = [
            application(bundleIdentifier: "   ", activationPolicy: .regular),
            application(signingIdentity: "", activationPolicy: .regular),
            application(processStartTimeUnixMs: 0, activationPolicy: .regular),
        ]
        for invalidCandidate in invalidCandidates {
            let inspector = HarnessAncestryFixture(
                parents: [100: 200, 200: 300, 300: 1],
                applications: [
                    200: invalidCandidate,
                    300: application(
                        name: "Outer Launcher",
                        bundleIdentifier: "com.example.outer-launcher",
                        activationPolicy: .regular
                    ),
                ]
            )

            #expect(HarnessProcessIdentityResolver.resolve(
                startingAt: 100,
                inspector: inspector
            ) == nil)
        }
    }

    @Test func validRegularWithoutPresentationNameUsesBundleIdentifier() throws {
        let inspector = HarnessAncestryFixture(
            parents: [100: 200, 200: 1],
            applications: [200: application(
                name: nil,
                bundleIdentifier: "com.example.valid-main",
                activationPolicy: .regular
            )]
        )

        let resolved = try #require(HarnessProcessIdentityResolver.resolve(
            startingAt: 100,
            inspector: inspector
        ))
        #expect(resolved.name == "com.example.valid-main")
        #expect(resolved.bundleIdentifier == "com.example.valid-main")
    }

    @Test func cyclesAndInvalidStartingProcessesFailClosed() {
        let cycle = HarnessAncestryFixture(
            parents: [100: 200, 200: 100],
            applications: [:]
        )
        #expect(HarnessProcessIdentityResolver.resolve(
            startingAt: 100,
            inspector: cycle
        ) == nil)
        #expect(HarnessProcessIdentityResolver.resolve(
            startingAt: 1,
            inspector: cycle
        ) == nil)
        #expect(HarnessProcessIdentityResolver.resolve(
            startingAt: -1,
            inspector: cycle
        ) == nil)
    }

    @Test func ancestryTraversalHonorsTheExactDepthBound() throws {
        var parents: [Int32: Int32] = [:]
        for processID in Int32(100)..<Int32(132) {
            parents[processID] = processID + 1
        }
        parents[132] = 1
        let tooDeep = HarnessAncestryFixture(
            parents: parents,
            applications: [132: application(
                name: "Too Deep",
                bundleIdentifier: "com.example.too-deep",
                activationPolicy: .regular
            )]
        )
        #expect(HarnessProcessIdentityResolver.resolve(
            startingAt: 100,
            inspector: tooDeep
        ) == nil)

        let atBoundary = HarnessAncestryFixture(
            parents: parents,
            applications: [131: application(
                name: "At Boundary",
                bundleIdentifier: "com.example.at-boundary",
                activationPolicy: .regular
            )]
        )
        let resolved = try #require(HarnessProcessIdentityResolver.resolve(
            startingAt: 100,
            inspector: atBoundary
        ))
        #expect(resolved.processID == 131)
        #expect(HarnessProcessIdentityResolver.maximumDepth == 32)
    }
}

private struct HarnessAncestryFixture: HarnessProcessAncestryInspecting {
    let parents: [Int32: Int32]
    let applications: [Int32: HarnessApplicationProcessSnapshot]

    func applicationSnapshot(processID: Int32) -> HarnessApplicationProcessSnapshot? {
        applications[processID]
    }

    func parentProcessID(of processID: Int32) -> Int32? {
        parents[processID]
    }
}

private func application(
    name: String? = "Harness",
    bundleIdentifier: String? = "com.example.harness",
    signingIdentity: String? = "fixture-signing",
    processStartTimeUnixMs: Int64? = 1_700_000_000_000,
    activationPolicy: HarnessApplicationActivationPolicy
) -> HarnessApplicationProcessSnapshot {
    HarnessApplicationProcessSnapshot(
        name: name,
        bundleIdentifier: bundleIdentifier,
        signingIdentity: signingIdentity,
        processStartTimeUnixMs: processStartTimeUnixMs,
        activationPolicy: activationPolicy
    )
}
