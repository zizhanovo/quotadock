import SwiftUI

// MARK: - 吸边方向 + 悬浮窗拖动手势
// （显式实现，不依赖 isMovableByWindowBackground 在 SwiftUI 上的表现）

/// 收起态吸边方向：左右 → 竖条，上下 → 横条
enum DockEdge: String, CaseIterable { case top, bottom, left, right }

struct WindowDragModifier: ViewModifier {
    @State private var startOrigin: NSPoint?
    @State private var cursorOffset = NSZeroPoint

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 2)
                // 不用 translation（它在随窗口移动的视图坐标系里，会形成反馈回路导致抖动），
                // 直接用鼠标全局坐标减去按下时的偏移来定位窗口
                .onChanged { _ in
                    guard let w = NSApp.windows.first(where: { $0 is NSPanel }) else { return }
                    let mouse = NSEvent.mouseLocation
                    if startOrigin == nil {
                        startOrigin = w.frame.origin
                        cursorOffset = NSPoint(x: mouse.x - startOrigin!.x, y: mouse.y - startOrigin!.y)
                    }
                    var f = w.frame
                    f.origin.x = mouse.x - cursorOffset.x
                    f.origin.y = mouse.y - cursorOffset.y
                    if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
                        let vis = s.visibleFrame
                        f.origin.x = min(max(f.origin.x, vis.minX), max(vis.minX, vis.maxX - f.width))
                        f.origin.y = min(max(f.origin.y, vis.minY), max(vis.minY, vis.maxY - f.height))
                    }
                    w.setFrame(f, display: true)
                }
                .onEnded { _ in
                    if let w = NSApp.windows.first(where: { $0 is NSPanel }) {
                        let mouse = NSEvent.mouseLocation
                        if let del = NSApp.delegate as? AppDelegate, del.store.stripMode {
                            // 吸边条拖拽结束：按落点最近的边重新吸附（左右=竖条 / 上下=横条）
                            del.stripDragEnded(mouse: mouse)
                        } else {
                            UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: "panelFrame")
                        }
                    }
                    startOrigin = nil
                }
        )
    }
}

extension View {
    func windowDrag() -> some View { modifier(WindowDragModifier()) }
}
