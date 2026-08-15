// 手表端 WCSession —— 接收 iPhone 推送的快照，发送「刷新 / 重试」消息。

import Foundation
import WatchConnectivity
import Observation

@MainActor
@Observable
final class WatchSession: NSObject {
    private(set) var snapshot: WatchSnapshot?
    /// 已向 iPhone 请求刷新、还没收到新快照
    private(set) var waiting = false

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        requestRefresh()
    }

    /// 让 iPhone 立即轮询一轮（结果经 applicationContext 推回）
    func requestRefresh() {
        let session = WCSession.default
        // 不可达（iPhone app 未运行/灭屏等）时不发实时消息，避免刷 not reachable 错误；
        // 快照会在 iPhone 下次轮询后经 applicationContext 自动送达
        guard session.activationState == .activated, session.isReachable else { return }
        waiting = true
        session.sendMessage(["refresh": true], replyHandler: nil) { [weak self] _ in
            Task { @MainActor in self?.waiting = false }
        }
    }

    /// 单台重试
    func retry(id: String) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["retry": id], replyHandler: nil, errorHandler: nil)
    }

    fileprivate func apply(context: [String: Any]) {
        guard let data = context["snapshot"] as? Data else { return }
        do {
            snapshot = try JSONDecoder().decode(WatchSnapshot.self, from: data)
        } catch {
            // 快照解码失败（两端版本不一致等）只记日志，不能静默丢数据
            print("[WatchSession] snapshot decode failed: \(error)")
            return
        }
        waiting = false
    }
}

// MARK: - WCSessionDelegate（回调在非主队列，跳回 MainActor）

extension WatchSession: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            // 激活完成后再请求一轮（首次配对场景 applicationContext 可能已在路上）
            if activationState == .activated { self.requestRefresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(context: applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.apply(context: userInfo) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(context: message) }
    }
}
