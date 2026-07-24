// swift-tools-version: 6.0
import PackageDescription

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
            path: "Sources/LumaBar"
        )
    ]
)
