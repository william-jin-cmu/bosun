// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bosun",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CBridge"),
        .executableTarget(
            name: "Bosun",
            dependencies: ["CBridge"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
