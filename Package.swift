// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MagnetPicker",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MagnetPicker", targets: ["MagnetPicker"])
    ],
    targets: [
        .executableTarget(
            name: "MagnetPicker",
            path: "Sources/MagnetPicker"
        )
    ],
    swiftLanguageVersions: [.v5]
)
