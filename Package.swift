// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ScreenWren",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ScreenWren", targets: ["ScreenWren"]),
        .executable(name: "ScreenWrenLoginItem", targets: ["ScreenWrenLoginItem"]),
    ],
    targets: [
        .executableTarget(
            name: "ScreenWren",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("PaperKit"),
                .linkedFramework("PencilKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Vision"),
                .linkedFramework("VisionKit"),
            ]
        ),
        .executableTarget(
            name: "ScreenWrenLoginItem",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "ScreenWrenTests",
            dependencies: ["ScreenWren"]
        ),
    ]
)
