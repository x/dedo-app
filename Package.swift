// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DEDO",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "VimKit")], // the vim editor, kept as its own package to reuse
    targets: [
        .target(name: "TodoCore"),
        .executableTarget(name: "DEDOApp", dependencies: ["TodoCore", .product(name: "VimKit", package: "VimKit")],
                          resources: [.copy("Fonts")]),
        .executableTarget(name: "dedo", dependencies: ["TodoCore"]), // the command line tool
        .testTarget(name: "TodoCoreTests", dependencies: ["TodoCore"]),
    ],
    swiftLanguageModes: [.v5]
)
