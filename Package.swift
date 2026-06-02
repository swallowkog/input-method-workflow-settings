// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "InputMethodAgent",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "input-method-agent", targets: ["InputMethodAgent"])
    ],
    targets: [
        .executableTarget(
            name: "InputMethodAgent",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
