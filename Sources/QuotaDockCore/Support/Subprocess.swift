import Foundation

// MARK: - 子进程运行器（数据源共用的 CLI 探针执行路）

/// 跑一条本机命令：argv 直传不经 shell（凭据与拼接注入面都不存在）。
enum Subprocess {
    /// 超时看门狗 SIGTERM、2s 后 SIGKILL；续体只在 terminationHandler 里恢复一次，
    /// 看门狗只负责杀，不负责恢复。
    static func run(bin: String, args: [String], timeout: TimeInterval,
                   environment: [String: String]? = nil) async
        -> (code: Int, out: String, err: String, timedOut: Bool) {
        final class RunState {
            private let lock = NSLock()
            private var resumed = false
            private(set) var timedOut = false
            func markTimedOut() {
                lock.lock(); defer { lock.unlock() }
                timedOut = true
            }
            func finish(_ resume: () -> Void) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                resume()
            }
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = args
                if let environment { p.environment = environment }
                // stdin 接 /dev/null：CLI 否则会空等 3s 管道输入（launchd 下同样），白白拖慢每轮
                p.standardInput = FileHandle.nullDevice
                let outPipe = Pipe()
                let errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                let state = RunState()
                p.terminationHandler = { proc in
                    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    state.finish { cont.resume(returning: (Int(proc.terminationStatus), out, err, state.timedOut)) }
                }
                do {
                    try p.run()
                } catch {
                    state.finish { cont.resume(returning: (-1, "", error.localizedDescription, false)) }
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    state.markTimedOut()
                    if p.isRunning {
                        p.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                        }
                    }
                }
            }
        }
    }
}
