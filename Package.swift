// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RevenueCatKit",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(
            name: "RevenueCatKit",
            targets: ["RevenueCatKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/RevenueCat/purchases-ios-spm.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "RevenueCatKit",
            dependencies: [
                .product(name: "RevenueCat", package: "purchases-ios-spm"),
            ]
        ),
        .testTarget(
            name: "RevenueCatKitTests",
            dependencies: ["RevenueCatKit"]
        ),
    ]
)
