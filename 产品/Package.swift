// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CodexAccounts", platforms: [.macOS(.v14)], products: [
    .library(name: "AccountCore", targets: ["AccountCore"]),
    .executable(name: "CodexAccounts", targets: ["AccountMenu"])
], targets: [
    .target(name: "AccountCore", linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "AccountMenu", dependencies: ["AccountCore"], resources: [.process("Resources")]),
    .testTarget(name: "AccountCoreTests", dependencies: ["AccountCore"]),
    .testTarget(name: "DesktopLifecycleTests", dependencies: ["AccountMenu", "AccountCore"])
])
