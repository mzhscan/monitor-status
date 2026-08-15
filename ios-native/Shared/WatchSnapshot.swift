// 手表快照模型 —— iPhone 端每次 poll 后通过 WatchConnectivity 推给手表。
// 只含手表展示需要的轻量字段（Codable），此文件同时加入 iPhone / Watch 两个 target。

import Foundation

struct WatchSnapshot: Codable {
    /// 快照生成时间（iPhone 端）
    var updatedAt: Date
    var servers: [WatchServer]

    var onlineCount: Int { servers.filter { $0.status == "online" }.count }
    var stalledCount: Int { servers.filter { $0.status == "stalled" }.count }
    var offlineCount: Int { servers.filter { $0.status == "offline" }.count }
}

struct WatchServer: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var isVps: Bool

    /// "online" | "stalled" | "offline" | "loading"
    var status: String
    /// 距最近一次 poll 成功的秒数（-1 = 从未成功）
    var secondsAgo: Int
    var error: String?

    // MARK: 硬件
    var cpuPct: Double?
    var cpuTemp: Double?
    var memPct: Double?
    var load1: Double?
    var uptime: String?
    /// 开机以来网络上下行总量（字节，来自 agent 的 /proc/net/dev 累计值）
    // 默认值 = nil 保证旧版 iPhone 包推来的快照（无此字段）也能解码成功
    var rxBytes: Int64? = nil
    var txBytes: Int64? = nil

    // MARK: xui（仅 VPS）
    var xuiOnline: Int?
    var xuiTotalClients: Int?
    var xuiTotalGb: Double?
    var traffic72hGb: Double?
}
