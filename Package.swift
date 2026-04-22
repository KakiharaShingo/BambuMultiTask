// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BambuMultiTask",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BambuMultiTask", targets: ["BambuMultiTask"])
    ],
    dependencies: [
        .package(url: "https://github.com/emqx/CocoaMQTT.git", from: "2.1.8")
    ],
    targets: [
        .executableTarget(
            name: "BambuMultiTask",
            dependencies: [
                .product(name: "CocoaMQTT", package: "CocoaMQTT")
            ],
            path: "Sources/BambuMultiTask"
        )
    ]
)
