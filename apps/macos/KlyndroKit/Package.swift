// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KlyndroKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KlyndroKit", targets: ["KlyndroKit"])
    ],
    dependencies: [
        // Apple's X.509 implementation. Used only to *encode* a self-signed certificate;
        // every signature is produced by a Security.framework key (see ADR 0008).
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0")
    ],
    targets: [
        .target(
            name: "KlyndroKit",
            dependencies: [
                .product(name: "X509", package: "swift-certificates")
            ]
        ),
        .testTarget(
            name: "KlyndroKitTests",
            dependencies: ["KlyndroKit"]
        )
    ]
)
