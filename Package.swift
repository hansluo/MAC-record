// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacRecord",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacRecord", targets: ["MacRecord"]),
    ],
    targets: [
        .executableTarget(
            name: "MacRecord",
            path: "MacRecord",
            exclude: [
                "Info.plist",
                "MacRecord.entitlements",
            ]
        ),
    ]
)
