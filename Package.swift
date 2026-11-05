// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Backlight",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Backlight",
            path: "Sources/Backlight",
            // Everything here is interface code; main-actor by default keeps
            // Swift 6's checking without annotating every type.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
