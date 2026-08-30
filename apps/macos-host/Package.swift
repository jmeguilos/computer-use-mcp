// swift-tools-version: 6.0

import PackageDescription
import Foundation

let commonSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
]

// Some Command Line Tools installations keep the test frameworks outside the
// default framework search path. Full Xcode finds these without this hint.
let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? "/Library/Developer/CommandLineTools"
let developerFrameworks = developerDirectory + "/Library/Developer/Frameworks"
let developerTestingLibraries = developerDirectory + "/Library/Developer/usr/lib"
let testSwiftSettings = commonSwiftSettings + [
    .unsafeFlags(["-F", developerFrameworks]),
]

let package = Package(
    name: "ComputerUseMCPHost",
    platforms: [
        .macOS("14.4"),
    ],
    products: [
        .library(name: "MacOSHostCore", targets: ["MacOSHostCore"]),
        .executable(name: "ComputerUseMCPHost", targets: ["MacOSHostApp"]),
        .executable(name: "ComputerUseMCPBridge", targets: ["MacOSHostBridge"]),
        .executable(name: "computer-use-mcp-fixture", targets: ["MacOSHostFixture"]),
    ],
    targets: [
        .target(
            name: "MacOSHostCore",
            swiftSettings: commonSwiftSettings,
            linkerSettings: [
                .linkedLibrary("bsm"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "MacOSHostApp",
            dependencies: ["MacOSHostCore"],
            swiftSettings: commonSwiftSettings
        ),
        .executableTarget(
            name: "MacOSHostBridge",
            dependencies: ["MacOSHostCore"],
            swiftSettings: commonSwiftSettings
        ),
        .executableTarget(
            name: "MacOSHostFixture",
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "MacOSHostCoreTests",
            dependencies: ["MacOSHostCore"],
            swiftSettings: testSwiftSettings,
            linkerSettings: [
                .unsafeFlags([
                    "-F", developerFrameworks,
                    "-Xlinker", "-rpath",
                    "-Xlinker", developerFrameworks,
                    "-Xlinker", "-rpath",
                    "-Xlinker", developerTestingLibraries,
                ]),
                .linkedFramework("Testing"),
            ]
        ),
    ]
)
