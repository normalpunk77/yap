// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Yap",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "YapCore"),
        // Tiny Objective-C shim: turns an uncatchable NSException into a Swift
        // error so AVFoundation calls (installTap) can't SIGABRT the app.
        .target(name: "ObjCExceptionCatcher"),
        .executableTarget(
            name: "YapApp",
            dependencies: ["YapCore", "ObjCExceptionCatcher"],
            path: "Sources/YapApp"
        ),
        .testTarget(
            name: "YapCoreTests",
            dependencies: ["YapCore", "ObjCExceptionCatcher", "YapApp"]
        ),
    ]
)
