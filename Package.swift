// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Atriya",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "Atriya", targets: ["Atriya"]),
    ],
    targets: [
        // The privacy manifest lists collected data and the reason for UserDefaults.
        .target(name: "Atriya", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(
            name: "AtriyaTests",
            dependencies: ["Atriya"],
            resources: [.copy("Fixtures")]
        ),
        // Command-line demo that sends a few events to a running backend.
        .executableTarget(
            name: "AtriyaDemo",
            dependencies: ["Atriya"],
            path: "Examples/AtriyaDemo"
        ),
    ]
)
