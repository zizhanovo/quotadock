// glm-ping — 用个人套餐（v1lite）的 GLM-5.3-Flash 发一个极小请求，"敲定" 5 小时窗口的起始时刻
// 用法：
//   glm-ping            敲一下 + 显示 5h 窗口状态
//   glm-ping status     只看当前窗口状态，不发请求
// 凭据：自动从 ~/.zcode/v2/credentials.json 解密个人账号 key（enc:v1 AES-256-GCM）
import Foundation
import CryptoKit

func b64url(_ s: String) -> Data {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)!
}

func beijing(_ date: Date) -> String {
    let f = DateFormatter()
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = date.timeIntervalSinceNow < 86400 ? "HH:mm" : "M月d日 HH:mm"
    return f.string(from: date)
}

func countdown(_ date: Date) -> String {
    let diff = date.timeIntervalSinceNow
    guard diff > 0 else { return "已滚动" }
    if diff < 3600 { return "\(Int(diff / 60))分钟" }
    if diff < 86400 { return "\(Int(diff / 3600))小时\(Int(diff.truncatingRemainder(dividingBy: 3600) / 60))分" }
    return "\(Int(diff / 86400))天\(Int(diff.truncatingRemainder(dividingBy: 86400) / 3600))小时"
}

let credPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".zcode/v2/credentials.json")
guard let raw = try? JSONSerialization.jsonObject(with: Data(contentsOf: credPath)) as? [String: String] else {
    print("❌ 读不到 ~/.zcode/v2/credentials.json"); exit(1)
}
let secret = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]
    ?? "zcode-credential-fallback:darwin:\(NSHomeDirectory()):\(NSUserName())"
let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))

func decrypt(_ v: String) -> String? {
    let parts = v.dropFirst("enc:v1:".count).components(separatedBy: ".")
    guard parts.count == 3,
          let nonce = try? AES.GCM.Nonce(data: b64url(parts[0])),
          let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: b64url(parts[2]), tag: b64url(parts[1])),
          let plain = try? AES.GCM.open(box, using: key) else { return nil }
    return String(decoding: plain, as: UTF8.self)
}

var apiKey = ""
for (k, v) in raw where k.contains("individual-coding-plan") && k.hasSuffix("api-key") {
    if let s = decrypt(v), s.count > 8 { apiKey = s; break }
}
guard !apiKey.isEmpty else { print("❌ 解密个人账号 key 失败"); exit(1) }

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ping"
let sem = DispatchSemaphore(value: 0)

func monitor(_ done: @escaping (String) -> Void) {
    var req = URLRequest(url: URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!)
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 20
    URLSession.shared.dataTask(with: req) { d, r, _ in
        let status = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let obj = try? JSONSerialization.jsonObject(with: d ?? Data()) as? [String: Any],
              let data = obj["data"] as? [String: Any],
              let limits = data["limits"] as? [[String: Any]] else {
            done("❌ 查询窗口状态失败 (HTTP \(status))"); sem.signal(); return
        }
        var lines: [String] = []
        for e in limits {
            let unit = (e["unit"] as? NSNumber)?.intValue ?? 0
            let pct = (e["percentage"] as? NSNumber)?.intValue ?? 0
            if unit == 3, let ts = (e["nextResetTime"] as? NSNumber)?.doubleValue {
                let reset = Date(timeIntervalSince1970: ts / 1000)
                lines.append("5h 窗口: 已用 \(pct)% ｜ \(countdown(reset))后滚动（北京 \(beijing(reset))）")
            } else if unit == 6, let ts = (e["nextResetTime"] as? NSNumber)?.doubleValue {
                let reset = Date(timeIntervalSince1970: ts / 1000)
                lines.append("周额度: 已用 \(pct)% ｜ \(countdown(reset))后滚动（北京 \(beijing(reset))）")
            }
        }
        if lines.isEmpty { lines.append("（暂无活跃窗口——敲一下即开始起算）") }
        done(lines.joined(separator: "\n")); sem.signal()
    }.resume()
}

func ping() {
    // URLSession HTTP/2 POST 到此端点会触发 -1103 "resource exceeds maximum size"（curl 正常），
    // 故改用 curl 子进程（--http1.1）
    let body = String(data: (try? JSONSerialization.data(withJSONObject: [
        "model": "glm-5.3-flash", "max_tokens": 8,
        "messages": [["role": "user", "content": "hi"]]
    ])) ?? Data(), encoding: .utf8) ?? "{}"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    proc.arguments = ["-sS", "--http1.1", "--max-time", "30",
                      "-H", "Authorization: Bearer \(apiKey)",
                      "-H", "Content-Type: application/json",
                      "-H", "anthropic-version: 2023-06-01",
                      "--data", body,
                      "https://open.bigmodel.cn/api/anthropic/v1/messages"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do { try proc.run() } catch { print("❌ curl 启动失败: \(error)"); sem.signal(); return }
    proc.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if proc.terminationStatus == 0, out.contains("msg_") || out.contains("\"type\":\"message\"") {
        print("✅ 已敲定：5 小时窗口从现在起算")
    } else {
        print("❌ 敲击失败: \(out.prefix(160))")
    }
    sem.signal()
}

if mode == "status" {
    monitor { print($0) }
    sem.wait()
} else {
    ping()
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
        monitor { print($0) }
    }
    sem.wait()   // 等 monitor 完成（ping 的信号已在 ping() 内部消费）
}
