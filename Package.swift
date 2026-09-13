// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VideoToLive",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VideoToLiveCore", targets: ["VideoToLiveCore"]),
        .executable(name: "vtl", targets: ["vtl"]),
        .executable(name: "VideoToLive", targets: ["VideoToLive"]),
    ],
    targets: [
        .target(
            name: "VideoToLiveCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "vtl",
            dependencies: ["VideoToLiveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Embed an Info.plist into the CLI binary so TCC can read
                // NSPhotoLibraryAddUsageDescription when we touch PhotoKit.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/vtl-Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "VideoToLive",
            dependencies: ["VideoToLiveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
