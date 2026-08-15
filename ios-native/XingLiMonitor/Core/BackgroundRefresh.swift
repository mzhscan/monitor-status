// 后台刷新（BGAppRefreshTask）：系统偶尔在后台唤醒 app 跑一轮轮询——
// 更新手表快照 + 补发离线/恢复通知。
// 唤醒频率由系统按使用习惯决定（常用 app 大约 15~30 分钟一次），
// 只能「基本跟得上」，无法替代前台的 5s 轮询。

import Foundation
import BackgroundTasks

final class BackgroundRefresh {
    static let shared = BackgroundRefresh()
    static let taskID = "com.mzhhua.monitorstatus.refresh"
    /// 请求的下次唤醒最早时间（实际何时执行由系统决定）
    private static let minInterval: TimeInterval = 15 * 60

    private var store: MonitorStore?

    private init() {}

    func attach(_ store: MonitorStore) { self.store = store }

    /// 必须在 app 启动时（App.init）调用，否则后台唤醒时没有回调入口
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskID, using: nil) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in self?.handle(task) }
        }
    }

    /// 安排下一次后台刷新（退后台时 / 每次被唤醒后调用）
    func scheduleNext() {
        let req = BGAppRefreshTaskRequest(identifier: Self.taskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: Self.minInterval)
        try? BGTaskScheduler.shared.submit(req)
    }

    @MainActor
    private func handle(_ task: BGAppRefreshTask) {
        // 先续上下一次，保证链条不断（即使本轮失败）
        scheduleNext()
        guard let store else {
            task.setTaskCompleted(success: false)
            return
        }
        var done = false
        let finish: (Bool) -> Void = { ok in
            guard !done else { return }
            done = true
            task.setTaskCompleted(success: ok)
        }
        // 兜底：系统只给约 30s 后台时间，25s 还没轮询完就强制交差
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            finish(false)
        }
        Task { @MainActor in
            // 后台冷启动场景（系统为 BGTask 拉起 app）：先补一次初始化
            if !store.firstLoadDone { await store.start() }
            store.backgroundPoll { finish(true) }
        }
    }
}
