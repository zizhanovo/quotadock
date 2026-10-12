import Foundation

/// 版本号唯一来源。build.sh 从这里提取（sed），release.sh 同源打 tag；
/// VersionConsistencyTests 保证提取不漂移。
enum QuotaVersion {
    static let current = "2.0.0"
}
