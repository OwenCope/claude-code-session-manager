// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SessionManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SessionManager", targets: ["SessionManager"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "SessionManager",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/SessionManager"
        )
    ]
)
