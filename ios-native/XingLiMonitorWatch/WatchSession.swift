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
        waiting = true
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.sendMessage(["refresh": true], replyHandler: nil) { [weak self] _ in
            Task { @MainActor in self?.waiting = false }
        }
    }

    /// 单台重试
    func retry(id: String) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.sendMessage(["retry": id], replyHandler: nil, errorHandler: nil)
    }

    fileprivate func apply(context: [String: Any]) {
        guard let data = context["snapshot"] as? Data,
              let snap = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else { return }
        snapshot = snap
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
