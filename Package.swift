// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "reaper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "reaper", targets: ["reaper"]),
        .executable(name: "ReaperApp", targets: ["ReaperApp"]),
        .library(name: "ReaperCore", targets: ["ReaperCore"]),
    ],
    targets: [
        .target(name: "ReaperCore"),
        .executableTarget(name: "reaper", dependencies: ["ReaperCore"]),
        // Bundled into Reaper.app by Scripts/make-app.sh.
        .executableTarget(name: "ReaperApp", dependencies: ["ReaperCore"]),
        .testTarget(name: "ReaperCoreTests", dependencies: ["ReaperCore"]),
    ]
)
