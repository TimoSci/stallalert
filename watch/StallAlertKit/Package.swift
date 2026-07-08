// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StallAlertKit",
    platforms: [.watchOS(.v11), .macOS(.v14)],
    products: [.library(name: "StallAlertKit", targets: ["StallAlertKit"])],
    targets: [
        .target(name: "StallAlertKit"),
        .testTarget(
            name: "StallAlertKitTests",
            dependencies: ["StallAlertKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
