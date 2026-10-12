import Foundation

// MARK: - Shell 安全：远端命令参数只走白名单，杜绝拼接注入

public enum ShellSafety {

    /// ssh host：别名 / IP / user@host / [v6]:port 形态，只允许这些字符
    public static func isSafeSSHHost(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 253 && s.allSatisfy { c in
            c.isLetter || c.isNumber || "._-:@[]".contains(c)
        }
    }

    /// 远端系统用户名（sudo -u 目标）：POSIX 惯例小写开头，允许 - _
    public static func isSafeUnixUsername(_ s: String) -> Bool {
        guard let first = s.first, first.isLowercase || first == "_", s.count <= 32 else { return false }
        return s.dropFirst().allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// 远端文件路径：绝对路径，仅字母数字 . _ - /（不允许空格/引号/变量/通配符）
    public static func isSafeRemotePath(_ s: String) -> Bool {
        s.hasPrefix("/") && s.count <= 4096 && s.allSatisfy { c in
            c.isLetter || c.isNumber || "._-/".contains(c)
        }
    }

    /// 白名单内的字符串用单引号包裹后可安全嵌入远端 sh 命令
    public static func singleQuoted(_ s: String) throws -> String {
        guard isSafeRemotePath(s) || isSafeUnixUsername(s) || isSafeSSHHost(s) else {
            throw ShellSafetyError.unsafeValue(String(s.prefix(40)))
        }
        return "'\(s)'"
    }

    public enum ShellSafetyError: Error, CustomStringConvertible {
        case unsafeValue(String)
        public var description: String {
            switch self {
            case .unsafeValue(let v): return "unsafe shell value: \(v)"
            }
        }
    }
}
