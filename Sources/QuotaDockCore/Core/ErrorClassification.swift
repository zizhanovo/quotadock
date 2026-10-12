import Foundation

// MARK: - HTTP / 响应 → SourceStatus 分类（纯函数，可测）

public enum FetchClassifier {

    /// 非 200 状态码分类。核心原则：**只有服务端明确拒绝该身份才算确认失效**，
    /// 429/5xx 等临时故障一律归为可重试，不触发 skip、不清数据。
    public static func status(forHTTP code: Int) -> SourceStatus {
        switch code {
        case 401, 403:
            return .unauthorized(confirmed: true)
        case 429:
            return .rateLimited
        case 500...599:
            return .serverError(status: code)
        default:
            // 其余非 200（3xx/4xx 等）按服务端异常对待，同样保留旧值
            return .serverError(status: code)
        }
    }

    /// 网络层错误（DNS/超时/断网）→ 临时故障
    public static func status(forNetworkError error: Error) -> SourceStatus {
        .networkError(error.localizedDescription)
    }

    /// 智谱 200 但无额度数据的细分：{"code":1000,"msg":"身份验证失败。"} 是唯一确认失效信号
    public static func zhipuInvalidPayload(_ data: Data?) -> SourceStatus {
        var message = "unparseable payload"
        var identityRejected = false
        if let data,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = obj["msg"] as? String { message = m }
            if (obj["code"] as? NSNumber)?.intValue == 1000 || message.contains("身份验证") {
                identityRejected = true
            }
        }
        return identityRejected ? .unauthorized(confirmed: true) : .invalidPayload(diagnostic: message)
    }

    /// 携带最近成功时间的状态展示文案："发生了什么 + 现在能做什么"
    public static func displayHint(for status: SourceStatus, lastGoodAt: Date?, language: String) -> String {
        let en = language == "en"
        switch status {
        case .success:
            return ""
        case .noDataYet(let hint):
            return hint
        case .networkError:
            return en
                ? "temporarily unreachable\(lastGoodAt.map { ", showing data from \(Self.hm($0))" } ?? ""); will retry automatically"
                : "暂时无法连接\(lastGoodAt.map { "，保留了 \(Self.hm($0)) 的数据" } ?? "")，稍后自动重试"
        case .rateLimited:
            return en
                ? "rate limited\(lastGoodAt.map { ", showing data from \(Self.hm($0))" } ?? ""); will retry later"
                : "接口限流\(lastGoodAt.map { "，保留了 \(Self.hm($0)) 的数据" } ?? "")，稍后自动重试"
        case .serverError(let code):
            return en
                ? "server error (\(code))\(lastGoodAt.map { ", showing data from \(Self.hm($0))" } ?? "")"
                : "服务端错误（\(code)）\(lastGoodAt.map { "，保留了 \(Self.hm($0)) 的数据" } ?? "")"
        case .unauthorized:
            return en ? "credential invalid" : "凭据失效"
        case .credentialStale(let hint):
            return hint
        case .invalidPayload(let diagnostic):
            return en
                ? "unexpected response\(lastGoodAt.map { ", showing data from \(Self.hm($0))" } ?? ""): \(diagnostic)"
                : "响应异常\(lastGoodAt.map { "，保留了 \(Self.hm($0)) 的数据" } ?? "")：\(diagnostic)"
        }
    }

    static func hm(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
