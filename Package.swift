// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PrivateCLIHost",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PrivateCLIHost", targets: ["PrivateCLIHost"])
    ],
    dependencies: [
        // SwiftTerm's 2.0 API is currently on main, without a 2.x release tag.
        // This revision was built against the host, so updates are deliberate.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "fe4fb45d5888ce33ff3788d6873870a73894a41b")
    ],
    targets: [
        .executableTarget(
            name: "PrivateCLIHost",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: ".",
            exclude: ["Packaging", "README.md", "ROADMAP.md", "LICENSE", "Tests", "Tools", "outputs", "versions"],
            sources: ["Sources/PrivateCLIHost"],
            resources: [.copy("Resources/agent-launcher.sh"), .copy("Resources/app-update.sh"), .copy("Resources/Fonts")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "PrivateCLIHostTests",
            dependencies: ["PrivateCLIHost"],
            path: "Tests/PrivateCLIHostTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
