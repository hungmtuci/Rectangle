// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Rectangle",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Rectangle", targets: ["Rectangle"])
    ],
    dependencies: [
        .package(url: "https://github.com/rxhanson/MASShortcut", revision: "2f9fbb3f959b7a683c6faaf9638d22afad37a235"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Rectangle",
            dependencies: [
                .product(name: "MASShortcut", package: "MASShortcut"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Rectangle",
            exclude: [
                "Assets.xcassets",
                "AppIcon.icon",
                "Base.lproj",
                "mul.lproj",
                "Localizable.xcstrings",
                "Logging/LogViewer.storyboard",
                "Popover/MessageView.xib",
                "Info.plist",
                "InternetAccessPolicy.plist",
                "Rectangle.entitlements",
                "RectangleRelease.entitlements",
                "Rectangle-Bridging-Header.h"
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-import-objc-header", "Rectangle/Rectangle-Bridging-Header.h"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "RectangleTests",
            dependencies: ["Rectangle"],
            path: "RectangleTests",
            exclude: [
                "Info.plist",
                "RectangleTests.swift",
                "GridTilingTests.swift",
                "DisplayTransferTests.swift",
                "ShortcutRecordingObserverTests.swift",
                "JSONDefaultTests.swift"
            ],
            sources: [
                "GreenButtonGridTests.swift"
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-import-objc-header", "Rectangle/Rectangle-Bridging-Header.h",
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
