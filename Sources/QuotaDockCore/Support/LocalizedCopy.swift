import Foundation

// MARK: - 双语文案集中地

/// 双语文案取值：config language = "en" 取英文，否则中文。
/// 语言从 ConfigurationStore 线程安全读取，热加载后下一次取值即生效。
/// 所有面向用户的字符串必须经 L() 或 FetchClassifier.displayHint，不在视图/数据源里散落硬编码。
public func L(_ zh: String, _ en: String) -> String {
    ConfigurationStore.shared.language == "en" ? en : zh
}
