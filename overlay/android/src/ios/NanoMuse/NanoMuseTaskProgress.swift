import Foundation

/// 下载进度观察器 —— 挂在 URLSessionTask 上，按固定间隔回调 0...1 的进度。
///
/// 为什么不用 URLSessionDownloadDelegate：
///   · SDK 下载是后台触发的（编译前检查），不需要 delegate 生命周期
///   · 这里只做一件事：读 task 的字节数 → 换算成比例
///
/// 进度来源 `countOfBytesExpectedToReceive`，服务端不给 Content-Length 时
/// 该值为 -1，此时退化为「无进度」，不回调。
final class NanoMuseTaskProgressMonitor {

    private let timer: DispatchSourceTimer

    init(task: URLSessionTask,
         interval: TimeInterval = 0.25,
         handler: @escaping (Double) -> Void) {
        // 闭包只捕获入参 task / handler（值类型引用），不碰 self，
        // 这样 self 在 timer 赋值前不会被读取，规避
        // "constant 'self.timer' used before being initialized"。
        let queue = DispatchQueue(label: "com.nanomuse.download.progress")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler {
            let total = task.countOfBytesExpectedToReceive
            guard total > 0 else { return }
            let ratio = Double(task.countOfBytesReceived) / Double(total)
            handler(min(max(ratio, 0), 1))
        }
        self.timer = t
    }

    func start() {
        timer.resume()
    }

    func stop() {
        timer.cancel()
    }
}
