import AppKit
import SwiftUI
import QuotaDockCore

// MARK: - 入口
// QUOTADOCK_RENDER=1 时离屏渲染面板 PNG 用于视觉检查（亮/暗 × 仪表盘/吸边条），否则正常运行。

@MainActor
private func renderSnapshotAndExit() {
    _ = NSApplication.shared
    // 渲染模式全部落临时目录：不读/不写用户的真实缓存与历史
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("qd-render-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = Store(config: .shared,
                      cache: CacheStore(url: tmp.appendingPathComponent("cache.json")),
                      skipList: SkipListStore(url: tmp.appendingPathComponent("skip.json"),
                                              legacyURL: tmp.appendingPathComponent("skip.txt")),
                      history: HistoryStore(url: tmp.appendingPathComponent("history.json")))
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
    if ProcessInfo.processInfo.environment["QUOTADOCK_DASHBOARD"] == "1" {
        // 大屏仪表盘离屏渲染：合成 7 天历史 + 现势 outcomes
        seedRenderFixtures(store)
        seedRenderHistory(store)
        let host = NSHostingView(rootView: AnyView(DashboardWindowView(store: store)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: NSSize(width: 760, height: 620))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: 760, height: max(620, size.height)))
        host.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * scale), pixelsHigh: Int(host.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = host.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1) : NSColor.white).setFill()
        NSBezierPath(rect: host.bounds).fill()
        host.displayIgnoringOpacity(host.bounds, in: NSGraphicsContext.current!)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUOTADOCK_OUT"] ?? "/tmp/quotadock-dashboard.png"))
        exit(0)
    }
    if ProcessInfo.processInfo.environment["QUOTADOCK_SETTINGS"] == "1" {
        let host = NSHostingView(rootView: AnyView(SettingsView(store: store)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: NSSize(width: 560, height: 600))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: max(560, size.width), height: max(600, size.height)))
        host.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * scale), pixelsHigh: Int(host.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = host.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSBezierPath(rect: host.bounds).fill()
        host.displayIgnoringOpacity(host.bounds, in: NSGraphicsContext.current!)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUOTADOCK_OUT"] ?? "/tmp/quotadock-settings.png"))
        exit(0)
    }
    let root = AnyView(PanelRootView(store: store))
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
        ExtraService(id: "codex:default", name: "Codex Pro", suffix: "PRO", usedPercent: 41,
                     weekBar: mk(41, 5 * 1440 + 21 * 60), resetFallback: "credits 3.5",
                     observedAt: Date().addingTimeInterval(-240)),
        ExtraService(id: "kimi:default", name: "Kimi", suffix: "", usedPercent: 44,
                     fiveBar: mk(0, 96), weekBar: mk(44, 5 * 1440), resetFallback: "",
                     observedAt: Date().addingTimeInterval(-1200)),
        ExtraService(id: "magpie:cursor", name: "Cursor", suffix: "Pro", usedPercent: 30,
                     fiveBar: mk(30, 26 * 1440), weekBar: mk(22, 22 * 60),
                     fiveLabel: "Other", weeklyLabel: "Grok",
                     resetFallback: "", observedAt: Date().addingTimeInterval(-300)),
        ExtraService(id: "mimo:default", name: "MiMo", suffix: "MiMo 进阶", usedPercent: 63,
                     resetFallback: L("重置 2026-10-13", "reset 2026-10-13"),
                     observedAt: Date().addingTimeInterval(-4 * 3600)),
        ExtraService(id: "cc:racknerd", name: "CC racknerd", suffix: "", usedPercent: 37,
                     fiveBar: mk(37, 240), weekBar: mk(5, 7 * 1440), resetFallback: "",
                     observedAt: Date().addingTimeInterval(-1800)),
        ExtraService(id: "cc:racknerd2", name: "CC racknerd2", suffix: "", usedPercent: 6,
                     fiveBar: mk(6, 180), weekBar: mk(1, 3 * 1440), resetFallback: "",
                     observedAt: Date().addingTimeInterval(-3 * 86400), stale: true),
        ExtraService(id: "kimi:err", name: "Kimi 2", suffix: "", usedPercent: nil,
                     resetFallback: "", observedAt: nil,
                     statusHint: L("token 过期 · 跑一次 kimi CLI 自动续期", "token expired · run kimi CLI to refresh")),
    ]
    store.lastUpdate = Date().addingTimeInterval(-120)
}

@MainActor
private func seedRenderHistory(_ store: Store) {
    // 大屏仪表盘渲染用：为每个身份合成 7 天、每 30 分钟一个点的锯齿状历史
    let now = Date().timeIntervalSince1970
    for (id, src, name, base) in [("zp:provider:bigmodel-api-2#J7Fk", "zhipu", "月卡2", 55.0),
                                  ("codex:default", "codex", "Codex Pro", 42.0),
                                  ("mimo:default", "mimo", "MiMo", 60.0),
                                  ("cc:racknerd", "claudeCode", "CC racknerd", 65.0)] {
        var points: [HistoryPoint] = []
        var t = now - 7 * 86400
        var i = 0
        while t < now {
            let wave = sin(Double(i) / 28 * .pi)                    // 日内爬升-重置锯齿
            let drift = (now - t) / (7 * 86400) * 18                // 周内趋势抬升
            let u = Int(min(100, max(2, base - 20 + wave * 30 + drift)))
            points.append(HistoryPoint(t: t, u: u, f: u, w: Int(min(100, base - 10 + drift))))
            t += 1800
            i += 1
        }
        for p in points { store.historyStore.append(identityKey: id, source: SourceID(rawValue: src)!, displayName: name, point: p) }
    }
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
