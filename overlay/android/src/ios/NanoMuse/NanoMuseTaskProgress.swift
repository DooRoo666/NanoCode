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

    private let task: URLSessionTask
    private let handler: (Double) -> Void
    private let timer: DispatchSourceTimer

    init(task: URLSessionTask,
         interval: TimeInterval = 0.25,
         handler: @escaping (Double) -> Void) {
        self.task = task
        self.handler = handler

        // queue 必须是局部变量：timer 的 eventHandler 捕获 self 时，
        // 属性尚未全部初始化完毕，直接引用会报 used-before-initialized。
        let queue = DispatchQueue(label: "com.nanomuse.download.progress")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        // [weak self] 断开 timer → self → timer 的引用环；
        // monitor 由调用方持有，调用方释放后 timer 自动失效。
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let total = self.task.countOfBytesExpectedToReceive
            guard total > 0 else { return }
            let ratio = Double(self.task.countOfBytesReceived) / Double(total)
            self.handler(min(max(ratio, 0), 1))
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
