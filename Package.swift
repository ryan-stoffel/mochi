// swift-tools-version: 5.10
import PackageDescription

// Mochi: the desktop pet, its agents and your AI plan usage, in one app.
//   MochiCore  usage sources, agent hooks and sessions, settings. No AppKit, so it's tested headlessly.
//   ptydrive   a tiny helper that drives a provider's CLI in a terminal, as a last-resort usage source.
//   Mochi      the app: the pet, its panel, the menu bar icon and dropdown, the notch, Settings, setup.
// The pages the app shows live in web/; ./build.sh copies them into the bundle.
let package = Package(
    name: "Mochi",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MochiCore"),
        // Fork/exec from a single-threaded helper rather than from the app: fork() after AppKit has started its
        // threads isn't async-signal-safe.
        .executableTarget(name: "ptydrive", dependencies: ["MochiCore"]),
        .executableTarget(name: "Mochi", dependencies: ["MochiCore"]),
        .testTarget(name: "MochiCoreTests", dependencies: ["MochiCore"], resources: [.copy("Fixtures")]),
    ]
)
