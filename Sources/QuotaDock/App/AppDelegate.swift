import AppKit
import SwiftUI
import Combine
import QuotaDockCore

// MARK: - NSApplication / NSPanel 生命周期

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: Store
    private var panel: NSPanel!
    private var placedInitially = false   // 完成"首次定位"前不保存位置、不落默认角
    private var cancellables: Set<AnyCancellable> = []

    init(store: Store) { self.store = store }

    func applicationDidFinishLaunching(_ note: Notification) {
        let host = NSHostingController(rootView: PanelRootView(store: store, onOpenSettings: { [weak self] in
            self?.openSettings()
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

        // 恢复上次位置
        if let saved = UserDefaults.standard.string(forKey: "panelFrame"),
           saved.contains("NSES") || saved.contains("{") {
            panel.setFrame(NSRectFromString(saved), display: true)
            if panel.frame.width > 50 { placedInitially = true }
        }
        panel.orderFrontRegardless()

        if !placedInitially {
            // SwiftUI 首次布局是异步的：先强制布局同步拿尺寸；拿不到就等首次 resize
            panel.layoutIfNeeded()
            host.view.layoutSubtreeIfNeeded()
            let fit = host.view.fittingSize
            if fit.width > 50, fit.height > 10 {
                panel.setContentSize(fit)
                placeTopRight()
            }
        }
        if !placedInitially {
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
                guard let self, !self.placedInitially, let p = self.panel, p.frame.width > 50 else { return }
                self.placeTopRight()
            }
        }
        // 尺寸变化后归位：吸边条模式贴齐吸附边（条宽<50，老 guard 会拦掉必须放行）；仪表盘模式拉回可见区
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, self.placedInitially, let panel = self.panel else { return }
            if self.store.stripMode {
                if panel.frame.width > 5 { self.dockFlush() }
            } else if panel.frame.width > 50 {
                self.clampToVisible()
            }
        }

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            // 吸边条期间不保存位置（panelFrame 只记仪表盘展开位，供恢复）
            guard let self, self.placedInitially, !self.store.stripMode,
                  let panel = self.panel, panel.frame.width > 50 else { return }
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "panelFrame")
        }

        // 从吸边条恢复展开：回到收起前的仪表盘位置
        store.$stripMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] strip in
                guard let self, !strip, self.placedInitially, let panel = self.panel else { return }
                if let saved = UserDefaults.standard.string(forKey: "panelFrame"),
                   saved.contains("{"), NSRectFromString(saved).width > 50 {
                    panel.setFrame(NSRectFromString(saved), display: true)
                }
                self.clampToVisible()
            }
            .store(in: &cancellables)

        store.start()
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
            settingsWindow = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 窗口任意一边超出可见区时拉回来（展开/收起后调用）；吸边条模式改为贴齐当前边
    private func clampToVisible() {
        guard let screen = NSScreen.main else { return }
        if store.stripMode { dockFlush(); return }
        let v = screen.visibleFrame
        var f = panel.frame
        var changed = false
        if f.maxX > v.maxX - 24 { f.origin.x = v.maxX - 24 - f.width; changed = true }
        if f.maxY > v.maxY - 8 { f.origin.y = v.maxY - 8 - f.height; changed = true } // 顶部贴菜单栏下方向下生长
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

    /// 吸边条贴齐当前边：贴边方向 0 间距，沿边坐标保留并夹回可见区
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
    }

    /// 贴屏幕可见区右上角（菜单栏/Dock 之下）
    private func placeTopRight() {
        placedInitially = true
        guard let screen = NSScreen.main else { return }
        var f = panel.frame
        f.origin = NSPoint(x: screen.visibleFrame.maxX - f.width - 24,
                           y: screen.visibleFrame.maxY - f.height - 8)
        panel.setFrame(f, display: true)
        Log.info("panel=\(NSStringFromRect(panel.frame)) screen.visible=\(NSStringFromRect(screen.visibleFrame))")
    }
}
