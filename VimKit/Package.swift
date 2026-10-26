// swift-tools-version: 6.0
import PackageDescription

// Vim keys for a macOS text view: a pure, testable engine plus an NSTextView adapter and a SwiftUI wrapper.
let package = Package(
    name: "VimKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "VimKit", targets: ["VimKit"])],
    targets: [
        .target(name: "VimKit"),
        .testTarget(name: "VimKitTests", dependencies: ["VimKit"]),
    ],
    swiftLanguageModes: [.v5]
)
