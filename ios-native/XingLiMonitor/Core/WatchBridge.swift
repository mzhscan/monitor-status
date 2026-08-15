// 手表桥接（伴生模式）—— iPhone 端职责：
// 1. 每次轮询结果落地后，把最新快照通过 WCSession applicationContext 推给手表；
// 2. 处理手表发来的「刷新 / 单台重试」消息；
// 3. 服务器 在线→离线 / 离线→在线 迁移时发本地通知（手表自动镜像震动）。

import Foundation
import WatchConnectivity
import UserNotifications

// 注：不能用 @MainActor 隔离（会破坏 WCSessionDelegate 协议 conformance），
// 需要主线程的操作在各方法内用 Task { @MainActor in } 跳回。
final class WatchBridge: NSObject, WCSessionDelegate, UNUserNotificationCenterDelegate {
    static let shared = WatchBridge()
    private var store: MonitorStore?
    /// serverId → 上一次 sync 时的状态（迁移判定用）
    private var prevStatus: [String: String] = [:]

    func attach(_ store: MonitorStore) {
        self.store = store
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        // 通知权限（离线/恢复提醒；锁屏+戴表时自动镜像到手表）
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - 快照推送

    /// 每次 poll 结果落地后调用：推快照 + 检查状态迁移（主线程调用）
    @MainActor
    func sync() {
        guard let store else { return }
        let snap = makeSnapshot(store)
        push(snap)
        notifyTransitions(snap)
    }

    private func push(_ snap: WatchSnapshot) {
        let session = WCSession.default
        // 注：isWatchAppInstalled 在直装（devicectl）场景下长时间不刷新，
        // 只查 isPaired；applicationContext 在手表无 app 时由系统静默丢弃，无副作用。
        guard session.isPaired else { return }
        guard let data = try? JSONEncoder().encode(snap) else { return }
        // applicationContext 自带合并：手表只会收到最新一份，正合适
        try? session.updateApplicationContext(["snapshot": data])
    }

    @MainActor
    private func makeSnapshot(_ store: MonitorStore) -> WatchSnapshot {
        var list: [WatchServer] = []
        for s in store.orderedServers {
            let d = store.agentFor(s)
            let err = store.errorFor(s)
            let ls = store.lastSuccessFor(s)
            let status: String
            let secondsAgo: Int
            if let ls {
                let sa = Int(Date().timeIntervalSince(ls).rounded())
                secondsAgo = sa
                if sa < 30 { status = "online" }
                else if sa < 300 { status = "stalled" }
                else { status = "offline" }
            } else {
                status = "loading"
                secondsAgo = -1
            }
            // 开机以来上下行总量（agent 读 /proc/net/dev 物理网卡累计）
            let net = d?.hardware?.network
            let xui = d?.xui
            list.append(WatchServer(
                id: s.id,
                name: s.name,
                isVps: d?.kind == "vps" || xui != nil,
                status: status,
                secondsAgo: secondsAgo,
                error: err,
                cpuPct: d?.hardware?.cpu?.percent,
                cpuTemp: d?.hardware?.cpu?.tempC,
                memPct: d?.hardware?.memory?.percent,
                load1: d?.hardware?.load?.l1,
                uptime: d?.hardware?.uptime,
                rxBytes: net.map { Int64($0.rxBytes) },
                txBytes: net.map { Int64($0.txBytes) },
                xuiOnline: xui?.onlineCount,
                xuiTotalClients: xui?.totalClients,
                xuiTotalGb: xui.map { $0.totalUpGb + $0.totalDownGb },
                traffic72hGb: xui.map { x in x.clients.compactMap(\.traffic72hGb).reduce(0, +) }
            ))
        }
        return WatchSnapshot(updatedAt: Date(), servers: list)
    }

    // MARK: - 离线 / 恢复通知

    @MainActor
    private func notifyTransitions(_ snap: WatchSnapshot) {
        defer {
            prevStatus = Dictionary(uniqueKeysWithValues: snap.servers.map { ($0.id, $0.status) })
        }
        // 首次 sync 只记录基线，不发通知（避免启动时刷屏）
        guard !prevStatus.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        for s in snap.servers {
            let old = prevStatus[s.id] ?? "loading"
            let wentDown = s.status == "offline" && old != "offline" && old != "loading"
            let recovered = s.status == "online" && old == "offline"
            guard wentDown || recovered else { continue }
            let content = UNMutableNotificationContent()
            content.title = "星黎监控"
            if wentDown {
                content.body = "「\(s.name)」离线了" + (s.error.map { "：\($0.prefix(60))" } ?? "")
            } else {
                content.body = "「\(s.name)」已恢复在线"
            }
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "xingli-\(s.id)-\(wentDown ? "down" : "up")-\(Int(Date().timeIntervalSince1970))",
                content: content, trigger: nil)
            center.add(req)
        }
    }

    // app 在前台时也弹横幅（否则前台期间通知静默不显示，也不会镜像到手表）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }
}

// MARK: - WCSessionDelegate（回调在后台队列，跳回 MainActor）

extension WatchBridge {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // 支持多手表切换场景：重新激活
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if message["refresh"] != nil {
                self.store?.refresh()
            }
            if let id = message["retry"] as? String {
                self.store?.pollServer(id: id)
            }
        }
    }
}
