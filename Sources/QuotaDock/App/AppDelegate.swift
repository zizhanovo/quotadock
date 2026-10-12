import AppKit
import SwiftUI
import Combine
import QuotaDockCore

// MARK: - NSApplication / NSPanel 生命周期
//
// v2.1 交互：启动即吸边条（默认收纳态），贴到记忆的边与位置；
// 展开面板锚定吸边条原位（pendingExpandAnchor），收纳回到最近的边并持久化锚点。

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: Store
    private var panel: NSPanel!
    private var host: NSHostingController<PanelRootView>!
    private var placedInitially = false   // 完成"首次定位"前不保存位置
    private var cancellables: Set<AnyCancellable> = []

    init(store: Store) { self.store = store }

    func applicationDidFinishLaunching(_ note: Notification) {
        store.stripMode = true   // 默认收纳态（render 模式不走到这里）
        host = NSHostingController(rootView: PanelRootView(store: store,
                                                           onOpenSettings: { [weak self] in
                                                               self?.openSettings()
                                                           },
                                                           onOpenDashboard: { [weak self] in
                                                               self?.openDashboard()
                                                           }))
        host.sizingOptions = .preferredContentSize
        panel = NSPanel(contentViewController: host)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false // 拖动由 SwiftUI 的 windowDrag() 显式处理，避免双重移动
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.orderFrontRegardless()

        // 首次布局是异步的：先强制布局同步拿尺寸；拿不到就等首次 resize
        panel.layoutIfNeeded()
        host.view.layoutSubtreeIfNeeded()
        let fit = host.view.fittingSize
        if fit.width > 5, fit.height > 5 {
            panel.setContentSize(fit)
            dockAtSavedAnchor()
        }

        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if !self.placedInitially {
                    if panel.frame.width > 5 {
                        if self.store.stripMode { self.dockAtSavedAnchor() } else { self.placeTopRight() }
                    }
                    return
                }
                if self.store.stripMode {
                    if panel.frame.width > 5 { self.dockFlush() }
                } else if panel.frame.width > 50 {
                    // 展开：优先锚定吸边条原位，否则只做可见区夹取
                    if let anchor = self.store.pendingExpandAnchor {
                        self.store.pendingExpandAnchor = nil
                        self.placePanel(at: anchor)
                    } else {
                        self.clampToVisible()
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.placedInitially, !self.store.stripMode,
                      let panel = self.panel, panel.frame.width > 50 else { return }
                UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "panelFrame")
            }
        }

        store.start()
    }

    // MARK: 定位：吸边条 ↔ 展开面板

    /// 启动/重置时：条贴到记忆的边（stripEdge）与沿边锚点（stripAnchor，缺省取边中点）
    private func dockAtSavedAnchor() {
        placedInitially = true
        guard let screen = NSScreen.main, let p = panel, p.frame.width > 5 else { return }
        let v = screen.visibleFrame
        let savedX = UserDefaults.standard.double(forKey: "stripAnchor.x")
        let savedY = UserDefaults.standard.double(forKey: "stripAnchor.y")
        var f = p.frame
        switch store.stripEdge {
        case .top:
            f.origin.y = v.maxY - f.height
            f.origin.x = savedX > 0 ? savedX - f.width / 2 : v.midX - f.width / 2
        case .bottom:
            f.origin.y = v.minY
            f.origin.x = savedX > 0 ? savedX - f.width / 2 : v.midX - f.width / 2
        case .left:
            f.origin.x = v.minX
            f.origin.y = savedY > 0 ? savedY - f.height / 2 : v.midY - f.height / 2
        case .right:
            f.origin.x = v.maxX - f.width
            f.origin.y = savedY > 0 ? savedY - f.height / 2 : v.midY - f.height / 2
        }
        f.origin.x = min(max(f.origin.x, v.minX), max(v.minX, v.maxX - f.width))
        f.origin.y = min(max(f.origin.y, v.minY), max(v.minY, v.maxY - f.height))
        p.setFrame(f, display: true)
    }

    /// 展开面板贴着吸边条原位出现：贴边方向 0 间距，沿边居中在条的中心
    private func placePanel(at anchor: (edge: DockEdge, point: NSPoint)) {
        guard let screen = NSScreen.main, let p = panel else { return }
        let v = screen.visibleFrame
        var f = p.frame
        switch anchor.edge {
        case .top: f.origin.y = v.maxY - f.height
        case .bottom: f.origin.y = v.minY
        case .left: f.origin.x = v.minX
        case .right: f.origin.x = v.maxX - f.width
        }
        if anchor.edge == .top || anchor.edge == .bottom {
            f.origin.x = anchor.point.x - f.width / 2
        } else {
            f.origin.y = anchor.point.y - f.height / 2
        }
        f.origin.x = min(max(f.origin.x, v.minX), max(v.minX, v.maxX - f.width))
        f.origin.y = min(max(f.origin.y, v.minY), max(v.minY, v.maxY - f.height))
        p.setFrame(f, display: true)
    }

    /// 窗口任意一边超出可见区时拉回来
    private func clampToVisible() {
        guard let screen = NSScreen.main else { return }
        if store.stripMode { dockFlush(); return }
        let v = screen.visibleFrame
        var f = panel.frame
        var changed = false
        if f.maxX > v.maxX { f.origin.x = v.maxX - f.width; changed = true }
        if f.maxY > v.maxY { f.origin.y = v.maxY - f.height; changed = true }
        if f.minX < v.minX { f.origin.x = v.minX; changed = true }
        if f.minY < v.minY { f.origin.y = v.minY; changed = true }
        if changed { panel.setFrame(f, display: true) }
    }

    /// 吸边条拖到新位置后调用：按鼠标落点最近的屏幕边重新吸附并持久化
    func stripDragEnded(mouse: NSPoint) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let v = screen?.visibleFrame, v.width > 0 else { return }
        let dists: [(DockEdge, CGFloat)] = [(.top, v.maxY - mouse.y), (.bottom, mouse.y - v.minY),
                                             (.left, mouse.x - v.minX), (.right, v.maxX - mouse.x)]
        if let e = dists.min(by: { $0.1 < $1.1 })?.0 {
            store.stripEdge = e
            UserDefaults.standard.set(e.rawValue, forKey: "stripEdge")
        }
        dockFlush()
    }

    /// 吸边条贴齐当前边：贴边方向 0 间距，沿边坐标保留并夹回可见区；锚点持久化
    private func dockFlush() {
        guard let screen = NSScreen.main, let p = panel, p.frame.width > 5 else { return }
        let v = screen.visibleFrame
        var f = p.frame
        switch store.stripEdge {
        case .top: f.origin.y = v.maxY - f.height
        case .bottom: f.origin.y = v.minY
        case .left: f.origin.x = v.minX
        case .right: f.origin.x = v.maxX - f.width
        }
        if store.stripEdge == .top || store.stripEdge == .bottom {
            f.origin.x = min(max(f.origin.x, v.minX), max(v.minX, v.maxX - f.width))
        } else {
            f.origin.y = min(max(f.origin.y, v.minY), max(v.minY, v.maxY - f.height))
        }
        p.setFrame(f, display: true)
        // 记住条的中心（重启回到原位）
        UserDefaults.standard.set(f.midX, forKey: "stripAnchor.x")
        UserDefaults.standard.set(f.midY, forKey: "stripAnchor.y")
    }

    /// 贴屏幕可见区右上角（无锚点时的兜底）
    private func placeTopRight() {
        placedInitially = true
        guard let screen = NSScreen.main else { return }
        var f = panel.frame
        f.origin = NSPoint(x: screen.visibleFrame.maxX - f.width - 24,
                           y: screen.visibleFrame.maxY - f.height - 8)
        panel.setFrame(f, display: true)
        Log.info("panel=\(NSStringFromRect(panel.frame)) screen.visible=\(NSStringFromRect(screen.visibleFrame))")
    }

    // MARK: 大屏仪表盘窗口（单实例；面板图表按钮打开）

    private var dashboardWindow: NSWindow?

    func openDashboard() {
        if let w = dashboardWindow {
            w.makeKeyAndOrderFront(nil)
        } else {
            let host = NSHostingController(rootView: DashboardWindowView(store: store))
            let w = NSWindow(contentViewController: host)
            w.title = "QuotaDock " + L("仪表盘", "Dashboard")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 760, height: 620))
            w.isReleasedWhenClosed = false
            w.center()
            dashboardWindow = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 设置窗口（单实例；面板齿轮按钮打开）

    private var settingsWindow: NSWindow?

    func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
        } else {
            let host = NSHostingController(rootView: SettingsView(store: store))
            let w = NSWindow(contentViewController: host)
            w.title = "QuotaDock " + L("设置", "Settings")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            // 设置窗口期间面板不自动收纳（配置时面板必须可见）；关掉后重新起收纳倒计时
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.store.settingsOpen = false
                    self.store.scheduleAutoCollapse()
                }
            }
            settingsWindow = w
            w.makeKeyAndOrderFront(nil)
        }
        store.settingsOpen = true
        store.noteHover(false)   // 焦点转去设置窗口：按"离开"处理，但 settingsOpen 挡住收纳
        NSApp.activate(ignoringOtherApps: true)
    }
}
