// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HTMLGraph",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "HTMLGraphCore", targets: ["HTMLGraphCore"]),
        .executable(name: "HTMLGraph", targets: ["HTMLGraph"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.8.8")
    ],
    targets: [
        .target(
            name: "HTMLGraphCore",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup")
            ]
        ),
        .executableTarget(
            name: "HTMLGraph",
            dependencies: [
                "HTMLGraphCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "HTMLGraphCoreTests",
            dependencies: ["HTMLGraphCore"]
        ),
        .testTarget(
            name: "HTMLGraphTests",
            dependencies: ["HTMLGraph"]
        )
    ]
)
