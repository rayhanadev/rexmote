// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "rexmote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "rexmote", targets: ["RexmoteCLI"]),
        .executable(name: "rexmote-host", targets: ["RexmoteHost"]),
    ],
    targets: [
        .target(name: "RexmoteCore", linkerSettings: [.linkedLibrary("z")]),
        .executableTarget(name: "RexmoteCLI", dependencies: ["RexmoteCore"]),
        .target(name: "VirtualDisplay", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]),
        .executableTarget(name: "RexmoteHost", dependencies: ["RexmoteCore", "VirtualDisplay"], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit"),
            .linkedFramework("ApplicationServices"), .linkedFramework("Accelerate"),
        ]),
        .testTarget(name: "RexmoteCoreTests", dependencies: ["RexmoteCore", "RexmoteCLI", "RexmoteHost"]),
    ]
)
