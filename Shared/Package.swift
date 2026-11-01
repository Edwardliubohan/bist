// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BistSync",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "BistSync", targets: ["BistSync"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "BistSync", dependencies: ["CSQLite"])
    ]
)
