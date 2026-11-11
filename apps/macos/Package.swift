// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "T3CodeAppKit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "T3Code", targets: ["T3Code"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.18.0"),
        .package(url: "https://github.com/clerk/clerk-ios.git", exact: "1.7.1"),
    ],
    targets: [
        .executableTarget(name: "T3Code", dependencies: [
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "ClerkKit", package: "clerk-ios"),
        ]),
        .testTarget(name: "T3CodeTests", dependencies: ["T3Code"]),
    ]
)
