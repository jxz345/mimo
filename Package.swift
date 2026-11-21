// swift-tools-version: 6.0
import PackageDescription

// This package validates the shared, non-UI logic on macOS or Linux.
// The SwiftUI app and WidgetKit extension are assembled as Xcode targets; see README.md.
let package = Package(
    name: "Mimo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MimoShared", targets: ["MimoShared"])
    ],
    targets: [
        .target(
            name: "MimoShared",
            path: "Sources/MimoShared"
        ),
        .testTarget(
            name: "MimoSharedTests",
            dependencies: ["MimoShared"],
            path: "Tests/MimoSharedTests"
        )
    ]
)
