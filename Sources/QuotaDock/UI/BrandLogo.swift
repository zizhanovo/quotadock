import SwiftUI

// MARK: - 品牌 logo：行视图与吸边条共用

enum BrandLogo {
    /// 名称 → 品牌图标 id（logos/ 目录下的同名 .svg/.png）；nil=无品牌图走首字块
    static func logoID(for name: String) -> String? {
        if name.hasPrefix("Codex") { return "openai" }
        if name.hasPrefix("CC ") { return "claude" }
        if name.hasPrefix("Kimi") { return "kimi" }
        if name.hasPrefix("MiMo") { return "xiaomi" }
        if name.hasPrefix("个人") || name.hasPrefix("Personal") { return "zhipu" }
        return nil
    }

    /// logo 目录：优先 QUOTADOCK_LOGOS 环境变量（离屏渲染用），否则 app bundle Resources/logos
    static func logosDir() -> URL? {
        if let p = ProcessInfo.processInfo.environment["QUOTADOCK_LOGOS"] { return URL(fileURLWithPath: p) }
        return Bundle.main.resourceURL?.appendingPathComponent("logos")
    }

    private static var logoCache: [String: NSImage?] = [:]
    static func logoImage(_ id: String) -> NSImage? {
        if let c = logoCache[id] { return c }
        var img: NSImage?
        for ext in ["svg", "png"] {
            if let u = logosDir()?.appendingPathComponent("\(id).\(ext)") {
                img = NSImage(contentsOf: u)
                if img != nil { break }
            }
        }
        img?.isTemplate = true   // 单色模板渲染，深浅模式统一 secondary 灰
        logoCache[id] = img
        return img
    }
}
