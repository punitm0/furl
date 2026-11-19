// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Furl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Furl", targets: ["Furl"])
    ],
    targets: [
        .executableTarget(
            name: "Furl",
            path: "Sources/Furl",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        // `swift test`. @testable import of an executable target works on macOS.
        .testTarget(
            name: "FurlTests",
            dependencies: ["Furl"],
            path: "Tests/FurlTests"
        ),
        // Developer-only benchmark harness. It compiles the app's Services and Models through the
        // symlinks in Sources/ScanBench/Linked so it can time the real scanners without touching the app.
        .executableTarget(
            name: "ScanBench",
            path: "Sources/ScanBench",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices")
            ]
        )
    ]
)
