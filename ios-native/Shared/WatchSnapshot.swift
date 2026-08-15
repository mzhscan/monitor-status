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
    /// 用量最高的前 2 块盘
    var topDisks: [WatchDisk]

    // MARK: xui（仅 VPS）
    var xuiOnline: Int?
    var xuiTotalClients: Int?
    var xuiTotalGb: Double?
    var traffic72hGb: Double?
}

struct WatchDisk: Codable, Hashable {
    var name: String
    var pct: Double
    var usedGb: Double
    var totalGb: Double
}
