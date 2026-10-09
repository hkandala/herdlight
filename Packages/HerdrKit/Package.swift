// swift-tools-version: 6.2

import PackageDescription

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "HerdrKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"]),
    ],
    targets: [
        .target(name: "HerdrKit", swiftSettings: strict),
        .testTarget(
            name: "HerdrKitTests",
            dependencies: ["HerdrKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: strict,
        ),
    ],
)
