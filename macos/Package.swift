// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoiseSharpening",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CNoiseSharpening"),
        .target(name: "NSKit", dependencies: ["CNoiseSharpening"]),
        .executableTarget(name: "NoiseSharpening", dependencies: ["NSKit"]),
    ],
    cxxLanguageStandard: .cxx17
)
