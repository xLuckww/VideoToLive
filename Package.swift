// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LivePhotoForge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LivePhotoForgeCore", targets: ["LivePhotoForgeCore"]),
        .executable(name: "lpforge", targets: ["lpforge"]),
        .executable(name: "LivePhotoForgeApp", targets: ["LivePhotoForgeApp"]),
    ],
    targets: [
        .target(
            name: "LivePhotoForgeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "lpforge",
            dependencies: ["LivePhotoForgeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Embed an Info.plist into the CLI binary so TCC can read
                // NSPhotoLibraryAddUsageDescription when we touch PhotoKit.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/lpforge-Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "LivePhotoForgeApp",
            dependencies: ["LivePhotoForgeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
