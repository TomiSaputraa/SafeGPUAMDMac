// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SafeGPU",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SafeGPUCore", targets: ["SafeGPUCore"]),
        .executable(name: "SafeGPU", targets: ["SafeGPUApp"]),
        .executable(name: "SafeGPUIconGen", targets: ["IconGen"])
    ],
    targets: [
        .target(
            name: "SafeGPUCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "SafeGPUApp",
            dependencies: ["SafeGPUCore"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "IconGen",
            dependencies: ["SafeGPUCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .testTarget(
            name: "SafeGPUCoreTests",
            dependencies: ["SafeGPUCore"]
        )
    ]
)
