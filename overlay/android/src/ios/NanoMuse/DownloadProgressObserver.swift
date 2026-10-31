import Foundation

/// 下载进度观察器 —— 挂在 URLSessionTask 上，按固定间隔回调已下载字节数。
///
/// 为什么不直接用 URLSessionDownloadDelegate：
///   · SDK 下载是后台触发的（编译前检查），不需要 UI 层的 delegate 生命周期
///   · 这个类只负责「读 task.countOfBytesReceived → 换算成 0...1」
///
/// 进度来源是 `task.countOfBytesExpectedToReceive`。
/// 服务端不返回 Content-Length 时该值为 -1，此时退化为「无进度」。
final class DownloadProgressObserver {

    private let task: URLSessionTask
    private let handler: (Double) -> Void
    private let timer: DispatchSourceTimer
    private let queue = DispatchQueue(label: "com.nanomuse.download.progress")

    /// 多久回调一次（秒）
    private let interval: TimeInterval

    init(task: URLSessionTask,
         interval: TimeInterval = 0.25,
         handler: @escaping (Double) -> Void) {
        self.task = task
        self.interval = interval
        self.handler = handler

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        self.timer = t
    }

    func start() {
        timer.resume()
    }

    func stop() {
        timer.cancel()
    }

    private func tick() {
        let total = task.countOfBytesExpectedToReceive
        // -1 表示服务端没给 Content-Length，此时不报告进度
        guard total > 0 else { return }
        let received = task.countOfBytesReceived
        let ratio = Double(received) / Double(total)
        handler(min(max(ratio, 0), 1))
    }
}
