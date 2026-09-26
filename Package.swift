// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BasicShell",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "BasicShell",
            path: "Sources/BasicShell",
            // Everything here is interface code; main-actor by default keeps
            // Swift 6's checking without annotating every type.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
