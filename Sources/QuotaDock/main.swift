import AppKit
import SwiftUI
import QuotaDockCore

// MARK: - 入口
// QUOTADOCK_RENDER=1 时离屏渲染面板 PNG 用于视觉检查（亮/暗 × 仪表盘/吸边条），否则正常运行。

@MainActor
private func renderSnapshotAndExit() {
    _ = NSApplication.shared
    let store = Store()
    if ProcessInfo.processInfo.environment["QUOTADOCK_STATE"] != "empty" {
        seedRenderFixtures(store)
    } else {
        store.keyQuotas = []
        store.extras = []
        store.lastError = L("未发现任何额度来源，检查各服务配置", "no quota sources found; check service configs")
    }
    if ProcessInfo.processInfo.environment["QUOTADOCK_STRIP"] == "1" {
        store.stripMode = true
        if let e = ProcessInfo.processInfo.environment["QUOTADOCK_EDGE"], let edge = DockEdge(rawValue: e) { store.stripEdge = edge }
    }
    let dark = ProcessInfo.processInfo.environment["QUOTADOCK_DARK"] == "1"
    let root = AnyView(PanelRootView(store: store, initiallyCollapsed: ProcessInfo.processInfo.environment["QUOTADOCK_STRIP"] == "1"))
    let host = NSHostingView(rootView: root)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    // 先用任意高度布局一次，等 SwiftUI 完成布局后再量真实尺寸
    host.frame = NSRect(origin: .zero, size: NSSize(width: 336, height: 50))
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // rep 的 DPI 已带 2x 缩放，这里不能重复 scaleBy，否则内容 4 倍渲染溢出裁切
    // 面板底色模拟 popover 材质
    (dark ? NSColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1) : NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    host.displayIgnoringOpacity(host.bounds, in: NSGraphicsContext.current!)
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUOTADOCK_OUT"] ?? "/tmp/quotadock-panel.png"))
    exit(0)
}

@MainActor
private func seedRenderFixtures(_ store: Store) {
    let mk = { (p5: Int, pw: Int) in LimitEntry(percentage: p5, usage: nil, currentValue: nil, nextResetTime: Date().timeIntervalSince1970 * 1000 + Double(pw) * 60_000) }
    store.keyQuotas = [
        KeyQuota(identityKey: "zp:provider:bigmodel-api-2#J7Fk", name: "周卡", keyTail: "J7Fk",
                 quota: QuotaData(fiveHour: mk(45, 288), weekly: mk(1, 7 * 1440),
                                  tools: LimitEntry(percentage: 1, usage: 4000, currentValue: 9,
                                                    nextResetTime: Date().timeIntervalSince1970 * 1000 + 30 * 1440 * 60_000),
                                  level: "max"), error: nil, lastGoodAt: Date().addingTimeInterval(-120)),
        KeyQuota(identityKey: "zp:provider:bigmodel-api#PbJy", name: "新卡", keyTail: "PbJy",
                 quota: QuotaData(fiveHour: mk(11, 115), weekly: mk(3, 4 * 1440), tools: nil, level: "max"),
                 error: nil, lastGoodAt: Date().addingTimeInterval(-120)),
    ]
    store.extras = [
        ExtraService(id: "codex:default", name: "Codex Pro", value: "41%", detail: "周窗口 · 重置 5天21小时后", usedPercent: 41),
        ExtraService(id: "kimi:default", name: "Kimi", value: "Allegretto", detail: "子瞻 · 已连接 · 无余额接口", usedPercent: nil),
        ExtraService(id: "mimo:default", name: "MiMo", value: "更新 15:12", detail: "已用 63% · 剩余 37% · 重置 2026-10-13 · MiMo 进阶", usedPercent: 63),
        ExtraService(id: "cc:racknerd", name: "CC racknerd", value: "更新 11:31", detail: "5h 37% · 周 5%", usedPercent: 37,
                     fiveBar: mk(37, 240), weekBar: mk(5, 7 * 1440)),
        ExtraService(id: "cc:racknerd2", name: "CC racknerd2", value: "⚠ 停更于 10/9 15:26", detail: "5h 6% · 周 1%", usedPercent: 6,
                     fiveBar: mk(6, 180), weekBar: mk(1, 3 * 1440), stale: true),
    ]
    store.lastUpdate = Date().addingTimeInterval(-120)
}

@MainActor
private func runApp() {
    let app = NSApplication.shared
    let store = Store()
    let delegate = AppDelegate(store: store)
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // 不显示 Dock 图标
    app.run()
}

if CommandLine.arguments.contains("--version") {
    print("QuotaDock \(QuotaVersion.current)")
    exit(0)
}

if ProcessInfo.processInfo.environment["QUOTADOCK_RENDER"] == "1" {
    MainActor.assumeIsolated { renderSnapshotAndExit() }
} else {
    MainActor.assumeIsolated { runApp() }
}
