// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NativeMail",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NativeMail", targets: ["NativeMail"])],
    targets: [
        .target(name: "WidgetShared"),
        .executableTarget(name: "NativeMail", dependencies: ["WidgetShared"]),
        .testTarget(name: "NativeMailTests", dependencies: ["NativeMail", "WidgetShared"])
    ]
)
