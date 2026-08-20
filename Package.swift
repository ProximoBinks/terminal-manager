// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TerminalManager",
            path: "Sources/TerminalManager",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        )
    ]
)
