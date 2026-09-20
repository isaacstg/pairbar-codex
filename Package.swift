// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CodexDualAccountSwitcher",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DualAccountSwitcher", targets: ["DualAccountSwitcher"])],
    targets: [
        .target(name: "ProcessIdentity", publicHeadersPath: "include"),
        .target(name: "SwitcherCore", dependencies: ["ProcessIdentity"]),
        .executableTarget(name: "DualAccountSwitcher", dependencies: ["SwitcherCore"]),
        .executableTarget(name: "SwitcherSmokeTest", dependencies: ["SwitcherCore"], path: "Tools/SmokeTest"),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore", "ProcessIdentity"]),
        .testTarget(name: "PairbarRuntimeTests", dependencies: ["DualAccountSwitcher", "SwitcherCore"])
    ]
)
