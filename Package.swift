// swift-tools-version:5.10
import PackageDescription

// FanPilot package layout (see docs/SPEC.md section 7).
//
//   CSMC               C layer: 80-byte SMC struct with layout asserts, AppleSMC user client calls,
//                      private IOHID temperature access resolved with dlsym.
//   FanPilotKit        Shared contracts: SMC codec/client, sensor and fan models, wire protocol,
//                      Unix socket framing, helper config, control policy and settings models.
//   FanPilotSensors    Sensor discovery, classification, readers, aggregates.
//   FanPilotControl    Pure control logic (RPM math, Auto Boost, curve, ramp).
//   FanPilotHelperCore Root daemon logic (fan writer, leases, failsafe, server).
//   fanpilotd          Root LaunchDaemon executable.
//   fanpilotctl        Command line tool.
//   FanPilotApp        SwiftUI menu bar app.
//
// The Swift language mode is pinned to 5 on purpose: it avoids Swift 6 strict-concurrency churn
// in code that talks to C APIs and GCD.

let ioKitLinking: [LinkerSetting] = [
    .linkedFramework("IOKit"),
    .linkedFramework("CoreFoundation"),
]

let package = Package(
    name: "FanPilot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FanPilotKit", targets: ["FanPilotKit"]),
        .library(name: "FanPilotSensors", targets: ["FanPilotSensors"]),
        .library(name: "FanPilotControl", targets: ["FanPilotControl"]),
        .library(name: "FanPilotHelperCore", targets: ["FanPilotHelperCore"]),
        .executable(name: "fanpilotd", targets: ["fanpilotd"]),
        .executable(name: "fanpilotctl", targets: ["fanpilotctl"]),
        .executable(name: "FanPilotApp", targets: ["FanPilotApp"]),
    ],
    targets: [
        // MARK: C layer
        .target(
            name: "CSMC",
            path: "Sources/CSMC",
            publicHeadersPath: "include",
            linkerSettings: ioKitLinking
        ),

        // MARK: Libraries
        .target(
            name: "FanPilotKit",
            dependencies: ["CSMC"],
            path: "Sources/FanPilotKit",
            linkerSettings: ioKitLinking
        ),
        .target(
            name: "FanPilotSensors",
            dependencies: ["FanPilotKit"],
            path: "Sources/FanPilotSensors",
            linkerSettings: ioKitLinking
        ),
        .target(
            name: "FanPilotControl",
            dependencies: ["FanPilotKit"],
            path: "Sources/FanPilotControl"
        ),
        .target(
            name: "FanPilotHelperCore",
            dependencies: ["FanPilotKit", "FanPilotSensors"],
            path: "Sources/FanPilotHelperCore",
            linkerSettings: ioKitLinking
        ),

        // MARK: Executables
        .executableTarget(
            name: "fanpilotd",
            dependencies: ["FanPilotHelperCore"],
            path: "Sources/fanpilotd"
        ),
        .executableTarget(
            name: "fanpilotctl",
            dependencies: ["FanPilotKit", "FanPilotSensors", "FanPilotControl", "FanPilotHelperCore"],
            path: "Sources/fanpilotctl"
        ),
        .executableTarget(
            name: "FanPilotApp",
            dependencies: ["FanPilotKit", "FanPilotSensors", "FanPilotControl"],
            path: "Sources/FanPilotApp"
        ),

        // MARK: Tests
        .testTarget(
            name: "FanPilotKitTests",
            dependencies: ["FanPilotKit", "CSMC"],
            path: "Tests/FanPilotKitTests"
        ),
        .testTarget(
            name: "FanPilotSensorsTests",
            dependencies: ["FanPilotSensors", "FanPilotKit"],
            path: "Tests/FanPilotSensorsTests"
        ),
        .testTarget(
            name: "FanPilotControlTests",
            dependencies: ["FanPilotControl", "FanPilotKit"],
            path: "Tests/FanPilotControlTests"
        ),
        .testTarget(
            name: "FanPilotHelperCoreTests",
            dependencies: ["FanPilotHelperCore", "FanPilotKit", "FanPilotSensors"],
            path: "Tests/FanPilotHelperCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
