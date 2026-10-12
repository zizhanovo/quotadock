// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuotaDock",
    platforms: [.macOS(.v13)],
    targets: [
        // 可测试的核心：模型、错误分类、刷新协调、配置、缓存、数据源
        .target(name: "QuotaDockCore", path: "Sources/QuotaDockCore"),
        // app 入口：NSApplication/NSPanel 生命周期 + SwiftUI 视图（通过 QUOTADOCK_RENDER 离屏渲染做视觉回归）
        .executableTarget(name: "QuotaDock", dependencies: ["QuotaDockCore"], path: "Sources/QuotaDock"),
        .testTarget(name: "QuotaDockTests", dependencies: ["QuotaDockCore"], path: "Tests/QuotaDockTests"),
    ]
)
