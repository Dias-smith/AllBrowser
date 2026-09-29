// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AllBrowserKits",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "StorageKit", targets: ["StorageKit"]),
        .library(name: "AppLockKit", targets: ["AppLockKit"]),
        .library(name: "AdBlockKit", targets: ["AdBlockKit"]),
        .library(name: "BrowserKit", targets: ["BrowserKit"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "PlaylistKit", targets: ["PlaylistKit"]),
        .library(name: "FilesKit", targets: ["FilesKit"]),
        .library(name: "PhotosKit", targets: ["PhotosKit"]),
        .library(name: "CachePhotosKit", targets: ["CachePhotosKit"]),
        .library(name: "YouTubeKit", targets: ["YouTubeKit"]),
    ],
    targets: [
        .target(name: "DesignSystem"),
        .target(name: "StorageKit"),
        .target(name: "AppLockKit", dependencies: ["StorageKit"]),
        .target(name: "AdBlockKit", dependencies: ["StorageKit"]),
        .target(name: "BrowserKit", dependencies: ["AdBlockKit", "StorageKit"]),
        .target(name: "MediaKit"),
        .target(name: "PlaylistKit", dependencies: ["StorageKit", "MediaKit"]),
        .target(name: "FilesKit", dependencies: ["StorageKit"]),
        .target(name: "PhotosKit"),
        .target(name: "CachePhotosKit", dependencies: ["StorageKit"]),
        .target(
            name: "YouTubeKit",
            dependencies: ["MediaKit", "StorageKit"]
        ),
    ]
)
