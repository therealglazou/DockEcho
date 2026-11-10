// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DockEcho",
    platforms: [.macOS("12.3")],   // 12.3: ScreenCaptureKit
    targets: [
        .executableTarget(name: "DockEcho", path: "Sources/DockEcho")
    ]
)
