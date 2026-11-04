// swift-tools-version:5.4
// For editors and `swift build`, which type-check and index the sources as one module.
// The app itself is built by scripts/build.sh, which puts the bundle together and signs it.
import PackageDescription

let package = Package(
  name: "PowerGauge",
  platforms: [.macOS(.v11)],
  targets: [
    // The kernel's diagnostic call, in C; build.sh gives its header to swiftc directly.
    .target(name: "CDiag", path: "Sources/CDiag"),
    .executableTarget(name: "PowerGauge", dependencies: ["CDiag"], path: "Sources/PowerGauge"),
  ]
)
