// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlashMDCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FlashMDCore", targets: ["FlashMDCore"])],
    targets: [
        .target(name: "USBBridge", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "FlashMDCore", dependencies: ["USBBridge"]),
        .testTarget(name: "FlashMDCoreTests", dependencies: ["FlashMDCore"])
    ]
)
