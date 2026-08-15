// 数据模型 —— 对齐 Flutter 版 app/lib/models.dart。
//
// Go backend / agent 的 JSON 数值字段大小不一，这里统一用辅助函数取值；
// 多种字段名 / 新旧 shape 兼容逻辑跟 Dart 版一一对应。

import Foundation

typealias JSON = [String: Any]

func jD(_ j: JSON, _ k: String) -> Double {
    if let n = j[k] as? NSNumber { return n.doubleValue }
    return 0.0
}

func jI(_ j: JSON, _ k: String) -> Int {
    if let n = j[k] as? NSNumber { return n.intValue }
    return 0
}

func jB(_ j: JSON, _ k: String) -> Bool {
    (j[k] as? NSNumber)?.boolValue == true
}

func jS(_ j: JSON, _ k: String) -> String {
    (j[k] as? String) ?? ""
}

func jObj(_ j: JSON, _ k: String) -> JSON? {
    j[k] as? JSON
}

func jArr(_ j: JSON, _ k: String) -> [JSON] {
    (j[k] as? [Any])?.compactMap { $0 as? JSON } ?? []
}

// MARK: - CPU / 内存 / GPU / 磁盘 / 负载 / 网络

struct CpuInfo {
    var model = ""
    var cores = 0
    var percent: Double = 0
    var tempC: Double = 0

    init(_ j: JSON) {
        model = jS(j, "model")
        cores = jI(j, "cores")
        let usage = jD(j, "usage")
        percent = usage > 0 ? usage : jD(j, "percent")
        tempC = jD(j, "temp_c")
    }

    var hasTemp: Bool { tempC > 0 }
    var hasModel: Bool { !model.isEmpty }
}

struct MemoryInfo {
    var percent: Double = 0
    var usedMb: Double = 0
    var totalMb: Double = 0
    var usedGb: Double { usedMb / 1024 }
    var totalGb: Double { totalMb / 1024 }

    init(_ j: JSON) {
        // Two shapes: new (bytes) { percent, total, used } / legacy { percent, used_mb, total_mb }
        percent = jD(j, "percent")
        let usedMbRaw = jD(j, "used_mb")
        let totalMbRaw = jD(j, "total_mb")
        if usedMbRaw > 0 || totalMbRaw > 0 {
            usedMb = usedMbRaw
            totalMb = totalMbRaw
        } else {
            usedMb = jD(j, "used") / (1024 * 1024)
            totalMb = jD(j, "total") / (1024 * 1024)
        }
    }
}

struct DiskEntry {
    var name = ""
    var mount = ""
    var device = ""
    var usedGb: Double = 0
    var totalGb: Double = 0
    var availGb: Double { totalGb - usedGb }
    var percent: Double = 0
    var tempC: Double?

    init(_ j: JSON) {
        // bytes { size, used } / legacy GB { total_gb, used_gb }
        var sizeBytes = jD(j, "size")
        var usedBytes = jD(j, "used")
        if sizeBytes <= 0 { sizeBytes = jD(j, "total_gb") * 1024 * 1024 * 1024 }
        if usedBytes <= 0 { usedBytes = jD(j, "used_gb") * 1024 * 1024 * 1024 }
        totalGb = sizeBytes / (1024 * 1024 * 1024)
        usedGb = usedBytes / (1024 * 1024 * 1024)
        var pct = jD(j, "percent")
        if pct <= 0 && sizeBytes > 0 {
            pct = usedBytes * 100 / sizeBytes
        }
        percent = pct
        name = jS(j, "name")
        mount = jS(j, "mount")
        device = jS(j, "device")
        tempC = (j["temp_c"] as? NSNumber)?.doubleValue
    }

    var hasTemp: Bool { (tempC ?? 0) > 0 }
}

/// sheet(item:) / ForEach 用：设备+挂载点足够唯一
extension DiskEntry: Identifiable {
    var id: String { "\(device)|\(mount)|\(name)" }
}

struct GpuInfo {
    var model: String?
    var percent: Double?
    var tempC: Double?
    var usedMb: Double?
    var totalMb: Double?

    init(_ j: JSON) {
        model = j["model"] as? String
        percent = (j["util"] as? NSNumber)?.doubleValue ?? (j["percent"] as? NSNumber)?.doubleValue
        tempC = (j["temp_c"] as? NSNumber)?.doubleValue
        usedMb = Self.vram(from: j, isTotal: false)
        totalMb = Self.vram(from: j, isTotal: true)
    }

    /// 多字段名兼容（*_mb → MB；*_bytes/无后缀 → bytes），对齐 Dart _vramFromJson。
    static func vram(from j: JSON, isTotal: Bool) -> Double? {
        let mbKeys = isTotal
            ? ["total_mb", "memory_total_mb", "vram_total_mb", "mem_total_mb", "memory_mb", "vram_mb"]
            : ["used_mb", "memory_used_mb", "vram_used_mb", "mem_used_mb", "memory_mb_used", "vram_mb_used"]
        for k in mbKeys {
            if let n = j[k] as? NSNumber, n.doubleValue > 0 { return n.doubleValue }
        }
        let bytesKeys = isTotal
            ? ["mem_total", "memory_total", "vram_total", "gpu_mem_total", "total_bytes", "memory_total_bytes", "vram_total_bytes"]
            : ["mem_used", "memory_used", "vram_used", "gpu_mem_used", "used_bytes", "memory_used_bytes", "vram_used_bytes"]
        for k in bytesKeys {
            if let n = j[k] as? NSNumber, n.doubleValue > 0 { return n.doubleValue / (1024 * 1024) }
        }
        // NVIDIA-smi 风格：used = total - free
        if !isTotal {
            let total = vram(from: j, isTotal: true)
            let free = (j["mem_free"] ?? j["memory_free"] ?? j["vram_free"]) as? NSNumber
            if let total, let free, free.doubleValue >= 0 {
                return min(max(total - free.doubleValue / (1024 * 1024), 0), total)
            }
        }
        return nil
    }

    var hasUtil: Bool { percent != nil }
    var hasTemp: Bool { (tempC ?? 0) > 0 }
    var hasMemory: Bool { usedMb != nil && totalMb != nil }
}

struct LoadInfo {
    var l1: Double = 0
    var l5: Double = 0
    var l15: Double = 0

    init(_ j: JSON) {
        l1 = jD(j, "1min")
        l5 = jD(j, "5min")
        l15 = jD(j, "15min")
    }
}

struct NetworkInfo {
    var rxBytes = 0
    var txBytes = 0
    var rxMb: Double = 0
    var txMb: Double = 0

    init(_ j: JSON) {
        func pickInt(_ keys: [String]) -> Int {
            for k in keys {
                let v = jI(j, k)
                if v != 0 { return v }
            }
            return 0
        }
        rxBytes = pickInt([
            "rx_bytes", "bytes_in", "bytes_recv", "in", "download",
            "received_bytes", "recv_bytes", "net_rx", "network_rx", "rx",
        ])
        txBytes = pickInt([
            "tx_bytes", "bytes_out", "bytes_sent", "out", "upload",
            "sent_bytes", "net_tx", "network_tx", "tx",
        ])
        rxMb = jD(j, "rx_mb")
        txMb = jD(j, "tx_mb")
        if rxMb <= 0 && rxBytes > 0 { rxMb = Double(rxBytes) / (1024 * 1024) }
        if txMb <= 0 && txBytes > 0 { txMb = Double(txBytes) / (1024 * 1024) }
    }
}

struct DiskInfo {
    var percent: Double = 0
    var usedGb: Double = 0
    var totalGb: Double = 0

    init(_ j: JSON) {
        percent = jD(j, "percent")
        usedGb = jD(j, "used_gb")
        totalGb = jD(j, "total_gb")
    }
}

struct Hardware {
    var cpu: CpuInfo?
    var memory: MemoryInfo?
    var gpu: GpuInfo?
    var disk: DiskInfo?
    var disks: [DiskEntry]?
    var load: LoadInfo?
    var network: NetworkInfo?
    var uptime = ""

    init(_ j: JSON) {
        cpu = jObj(j, "cpu").map(CpuInfo.init)
        if let mem = jObj(j, "memory") {
            // 新 shape 用 bytes，legacy 用 _mb/_gb（对齐 Dart hasLegacyMem 分支）
            let hasLegacy = mem["used_mb"] != nil || mem["used_gb"] != nil
            if hasLegacy {
                var legacy: JSON = ["percent": mem["percent"] ?? 0]
                legacy["used_mb"] = mem["used_mb"] ?? (jD(mem, "used_gb") * 1024)
                legacy["total_mb"] = mem["total_mb"] ?? (jD(mem, "total_gb") * 1024)
                memory = MemoryInfo(legacy)
            } else {
                memory = MemoryInfo(mem)
            }
        }
        gpu = jObj(j, "gpu").map(GpuInfo.init)
        disk = jObj(j, "disk").map(DiskInfo.init)
        if let arr = j["disks"] as? [Any] {
            disks = arr.compactMap { ($0 as? JSON).map(DiskEntry.init) }
        }
        load = jObj(j, "load").map(LoadInfo.init)
        // Network 可能挂在好几个 key 下
        for k in ["network", "net", "net_io", "netio", "bandwidth"] {
            if let n = jObj(j, k) {
                network = NetworkInfo(n)
                break
            }
        }
        uptime = jS(j, "uptime")
    }
}

// MARK: - 3x-ui

struct XuiClient {
    var email = ""
    var online = false
    var enable = false
    var upBytes = 0
    var downBytes = 0
    var upGb: Double = 0
    var downGb: Double = 0
    var lastOnline = 0
    var traffic72hGb: Double?

    init(_ j: JSON) {
        email = jS(j, "email")
        online = jB(j, "online")
        enable = jB(j, "enable")
        upBytes = jI(j, "up_bytes")
        downBytes = jI(j, "down_bytes")
        upGb = jD(j, "up_gb")
        downGb = jD(j, "down_gb")
        lastOnline = jI(j, "last_online")
        // 72h 流量：多字段兼容（对齐 Dart parse72h）
        if let n = (j["traffic_72h_gb"] ?? j["bytes_72h_gb"]) as? NSNumber {
            traffic72hGb = n.doubleValue
        } else if let n = (j["traffic_72h_bytes"] ?? j["bytes_72h"]) as? NSNumber {
            traffic72hGb = n.doubleValue / (1024 * 1024 * 1024)
        } else if let up = j["up_72h_bytes"] as? NSNumber, let down = j["down_72h_bytes"] as? NSNumber {
            traffic72hGb = (up.doubleValue + down.doubleValue) / (1024 * 1024 * 1024)
        }
    }

    var totalBytes: Int { upBytes + downBytes }
    var totalGb: Double { upGb + downGb }
}

struct XuiInbound {
    var remark = ""
    var port = 0
    var enable = false
    var upBytes = 0
    var downBytes = 0
    var upGb: Double = 0
    var downGb: Double = 0

    init(_ j: JSON) {
        remark = jS(j, "remark")
        port = jI(j, "port")
        enable = jB(j, "enable")
        upBytes = jI(j, "up_bytes")
        downBytes = jI(j, "down_bytes")
        upGb = jD(j, "up_gb")
        downGb = jD(j, "down_gb")
    }
}

/// v2.4.20: 所有 enabled inbound 的实时流量累加（xray 实时写入，秒级刷新）
struct InboundTotal {
    var upBytes = 0
    var downBytes = 0
    var upGb: Double = 0
    var downGb: Double = 0
    var inboundsCount = 0

    init(_ j: JSON) {
        upBytes = jI(j, "up_bytes")
        downBytes = jI(j, "down_bytes")
        upGb = jD(j, "up_gb")
        downGb = jD(j, "down_gb")
        inboundsCount = jI(j, "inbounds_count")
    }
}

struct XuiInfo {
    var onlineCount = 0
    var totalClients = 0
    var totalUpGb: Double = 0
    var totalDownGb: Double = 0
    var clients: [XuiClient] = []
    var inbounds: [XuiInbound] = []
    var inboundTotal: InboundTotal?
    var observedAt = 0
    var error: String?

    init(_ j: JSON) {
        onlineCount = jI(j, "online_count")
        totalClients = jI(j, "total_clients")
        totalUpGb = jD(j, "total_up_gb")
        totalDownGb = jD(j, "total_down_gb")
        clients = jArr(j, "clients").map(XuiClient.init)
        inbounds = jArr(j, "inbounds").map(XuiInbound.init)
        inboundTotal = jObj(j, "inbound_total").map(InboundTotal.init)
        observedAt = jI(j, "observed_at")
        let err = jS(j, "_error")
        error = err.isEmpty ? nil : err
    }
}

struct ServiceEntry {
    var name = ""
    var status = ""

    init(_ j: JSON) {
        name = jS(j, "name")
        status = jS(j, "status")
    }

    var isActive: Bool { status == "active" }
    var isFailed: Bool { status == "failed" }
}

// MARK: - Server 配置（持久化到 UserDefaults，兼容 Flutter 版 JSON）

struct MonitorServer: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var user: String = "agent"
    var kind: String = "agent"      // "agent" | "ssh"
    var https: Bool = false
    var agentUrl: String?
    var relayUrl: String?
    var diskAliases: [String: String] = [:]
    var hiddenDisks: [String: Bool] = [:]
    var createdAt: Int = 0
    var updatedAt: Int = 0
    var sortOrder: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, user, kind, https
        case agentUrl = "agent_url"
        case relayUrl = "relay_url"
        case diskAliases = "disk_aliases"
        case hiddenDisks = "hidden_disks"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sortOrder = "sort_order"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        let nm = (try? c.decode(String.self, forKey: .name)) ?? ""
        host = (try? c.decode(String.self, forKey: .host)) ?? ""
        name = nm.isEmpty ? host : nm
        port = (try? c.decode(Int.self, forKey: .port)) ?? 0
        user = (try? c.decode(String.self, forKey: .user)) ?? ""
        let kd = (try? c.decode(String.self, forKey: .kind)) ?? ""
        kind = kd.isEmpty ? "ssh" : kd
        https = (try? c.decode(Bool.self, forKey: .https)) ?? false
        agentUrl = try? c.decode(String.self, forKey: .agentUrl)
        relayUrl = try? c.decode(String.self, forKey: .relayUrl)
        createdAt = (try? c.decode(Int.self, forKey: .createdAt)) ?? 0
        updatedAt = (try? c.decode(Int.self, forKey: .updatedAt)) ?? 0
        sortOrder = (try? c.decode(Int.self, forKey: .sortOrder)) ?? 0
        // disk_aliases / hidden_disks：老数据带这俩字段也读进来（新数据由
        // disk_config.json 文件管）
        diskAliases = (try? c.decode([String: String].self, forKey: .diskAliases)) ?? [:]
        hiddenDisks = (try? c.decode([String: Bool].self, forKey: .hiddenDisks)) ?? [:]
    }

    init(id: String, name: String, host: String, port: Int, https: Bool,
         agentUrl: String?, relayUrl: String? = nil, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = "agent"
        self.kind = "agent"
        self.https = https
        self.agentUrl = agentUrl
        self.relayUrl = relayUrl
        self.sortOrder = sortOrder
    }

    /// 真正用来拉数据的 URL（v2.4.26+）：relay 优先。
    func effectiveEndpoint() -> String {
        if let relay = relayUrl, !relay.isEmpty {
            let base = relay.hasSuffix("/") ? String(relay.dropLast()) : relay
            return "\(base)/api/report"
        }
        return agentUrl ?? ""
    }

    var isAgent: Bool { kind == "agent" }

    var displayLocation: String {
        if isAgent {
            let u = (agentUrl?.isEmpty == false) ? agentUrl! : host
            return "\(u)  ·  agent"
        }
        return "\(host):\(port)  ·  \(user)"
    }
}

// MARK: - Agent 返回数据

struct AgentData {
    var name: String
    var id: String
    var kind: String        // "nas" | "vps"
    var source: String      // "agent" | "ssh"
    var timestamp: Int
    var secondsAgo: Int
    var online: Bool
    var hardware: Hardware?
    var xui: XuiInfo?
    var services: [ServiceEntry]

    /// 对齐 Dart AgentData.fromJson：v2.0.0 agent flat shape + legacy
    /// backend { data, last_update, seconds_ago } wrapper。
    init?(_ j: JSON) {
        // legacy backend shape
        if let data = jObj(j, "data") {
            let name = jS(data, "name")
            let xuiMap = jObj(data, "xui")
            let kindRaw = jS(data, "kind")
            var kind = kindRaw.isEmpty ? "nas" : kindRaw
            if kind == "nas" && xuiMap != nil { kind = "vps" }
            let nm = name.isEmpty ? jS(data, "agent_name") : name
            self.name = nm
            self.id = jS(data, "id")
            self.kind = kind
            let src = jS(data, "source")
            self.source = src.isEmpty ? "agent" : src
            self.timestamp = jI(j, "last_update")
            self.secondsAgo = jI(j, "seconds_ago")
            self.online = jB(data, "online")
            self.hardware = jObj(data, "hardware").map(Hardware.init)
            self.xui = xuiMap.map(XuiInfo.init)
            self.services = jArr(data, "services").map(ServiceEntry.init)
            return
        }

        // v2.0.0 agent direct shape
        let tsSec = jI(j, "timestamp")
        let secondsAgo = tsSec > 0
            ? Int((Double(Date().timeIntervalSince1970) - Double(tsSec)).rounded())
            : 0
        let hasXui = jObj(j, "xui") != nil
        self.name = jS(j, "agent_name")
        self.id = ""
        self.kind = hasXui ? "vps" : "nas"
        self.source = "agent"
        self.timestamp = tsSec
        self.secondsAgo = secondsAgo
        self.online = true
        self.hardware = jObj(j, "hardware").map(Hardware.init)
        self.xui = jObj(j, "xui").map(XuiInfo.init)
        self.services = jArr(j, "services").map(ServiceEntry.init)
    }

    var isOnline: Bool { online && secondsAgo >= 0 && secondsAgo < 30 }
    var isVps: Bool { kind == "vps" }
    var hasXui: Bool { xui != nil }
}
