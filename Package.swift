// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "herdr-voice",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Speech for the native local helper only (Parakeet and Kokoro on the Neural Engine); see
        // docs/speech-engine-spike.md. herdr-voice and HerdrVoiceCore stay dependency-free.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
    ],
    targets: [
        .target(name: "HerdrVoiceCore"),
        .executableTarget(name: "herdr-voice", dependencies: ["HerdrVoiceCore"]),
        .target(name: "HerdrVoiceLocal"),
        .executableTarget(name: "herdr-voice-local", dependencies: [
            "HerdrVoiceLocal",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .testTarget(name: "HerdrVoiceTests", dependencies: ["HerdrVoiceCore"]),
        .testTarget(name: "HerdrVoiceLocalTests", dependencies: ["HerdrVoiceLocal", "HerdrVoiceCore"]),
    ]
)
