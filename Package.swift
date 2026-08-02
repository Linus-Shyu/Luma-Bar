// swift-tools-version: 6.0
import PackageDescription

let isAppStore = Context.environment["LUMA_APP_STORE"] == "1"

let package = Package(
    name: "LumaBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LumaBar", targets: ["LumaBar"])
    ],
    targets: [
        .executableTarget(
            name: "LumaBar",
            path: "Sources/LumaBar",
            swiftSettings: isAppStore ? [.define("LUMA_APP_STORE")] : []
        )
    ]
)
