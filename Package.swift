// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexAccountSwitcher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SwitcherCore", targets: ["SwitcherCore"]),
        .executable(name: "CodexAccountSwitcher", targets: ["CodexAccountSwitcher"])
    ],
    targets: [
        .target(
            name: "SwitcherCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "CodexAccountSwitcher",
            dependencies: ["SwitcherCore"]
        ),
        .testTarget(
            name: "SwitcherCoreTests",
            dependencies: ["SwitcherCore"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
