// 本地状态 store —— 对齐 Flutter 版 app/lib/store.dart。
//
// 没有 backend：每台 MonitorServer 各自一个 AgentClient，5s 轮询。
// 服务器列表持久化在 NSUserDefaults（key 跟 Flutter 版 SharedPreferences
// 相同：flutter.monitor_servers_v2），token 双写 Keychain + UserDefaults。

import Foundation
import Observation

@MainActor
@Observable
final class MonitorStore {
    static let serversKey = "flutter.monitor_servers_v2"
    static let diskConfigFileName = "disk_config.json"

    // MARK: UI 可观察状态

    private(set) var servers: [MonitorServer] = []
    /// serverId → 最新一次成功拉到的数据
    private(set) var data: [String: AgentData] = [:]
    /// serverId → 最近一次错误（中文，已过 explainError）
    private(set) var serverErrors: [String: String] = [:]
    /// serverId → app 端 poll 成功时间（状态判定用这个，不用 agent 自报）
    private(set) var lastSuccess: [String: Date] = [:]
    private(set) var isLoading = false
    /// 聚合错误（全部失败且没数据时整页错误用）
    private(set) var error: String?
    private(set) var firstLoadDone = false
    private(set) var trustedCertCount = 0

    // MARK: 内部状态（不参与观察）

    @ObservationIgnored private var clients: [String: AgentClient] = [:]
    @ObservationIgnored private var tokens: [String: String] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var polling = false

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0.0"
    }

    // MARK: - 派生数据

    /// 显示顺序：sortOrder（tie-break name），对齐 Dart orderedServers
    var orderedServers: [MonitorServer] {
        servers.sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return a.name.localizedLowercase < b.name.localizedLowercase
        }
    }

    /// 全部 server 都失败且没有任何数据 → 整页错误
    var isAllFailed: Bool {
        error != nil && data.isEmpty
    }

    var lastSuccessAt: Date? {
        lastSuccess.values.max()
    }

    func agentFor(_ s: MonitorServer) -> AgentData? { data[s.id] }
    func errorFor(_ s: MonitorServer) -> String? { serverErrors[s.id] }
    func lastSuccessFor(_ s: MonitorServer) -> Date? { lastSuccess[s.id] }
    func tokenFor(_ id: String) -> String? { tokens[id] }

    // MARK: - 启动

    func start() async {
        guard !firstLoadDone else { return }
        TrustStore.refreshCache()
        trustedCertCount = TrustStore.loadAll().count

        let (saved, legacyTokens) = loadServers()
        servers = saved
        for s in saved {
            var tok = TokenStore.load(id: s.id)
            if tok == nil, let legacy = legacyTokens[s.id] {
                // 一次性迁移 v2.2.x 老 JSON 内嵌 token → Keychain + UserDefaults
                TokenStore.save(id: s.id, token: legacy)
                tok = legacy
            }
            tokens[s.id] = tok ?? ""
            if s.kind == "agent", let url = s.agentUrl, !url.isEmpty,
               let tok, !tok.isEmpty {
                clients[s.id] = AgentClient(endpoint: relayBase(s) ?? url, token: tok)
            }
        }
        if !legacyTokens.isEmpty {
            saveServers(stripLegacyTokens: true)
        }
        await loadDiskConfig()
        firstLoadDone = true

        // 手表伴生：激活 WCSession，后续每次 poll 落地后推快照
        WatchBridge.shared.attach(self)
        // 后台刷新：登记 store，退后台时由 RootView 安排 BGTask
        BackgroundRefresh.shared.attach(self)

        tickAll()
        // Bug #6 fix: 5s 轮询，跟 agent 的 5s probe 间隔对齐
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickAll() }
        }
    }

    /// relay 模式：endpoint 用 relay 的 base URL（token 路由），对齐 effectiveEndpoint
    private func relayBase(_ s: MonitorServer) -> String? {
        guard let relay = s.relayUrl, !relay.isEmpty else { return nil }
        return relay.hasSuffix("/") ? String(relay.dropLast()) : relay
    }

    // MARK: - 轮询

    private func tickAll() {
        guard !polling else { return }
        polling = true
        isLoading = true
        let jobs: [(String, AgentClient)] = clients.map { ($0.key, $0.value) }
        Task { [weak self] in
            var newData: [String: AgentData] = [:]
            var newErrors: [String: String] = [:]
            var newSuccess: [String: Date] = [:]
            await withTaskGroup(of: (String, Result<AgentData, Error>).self) { group in
                for (id, client) in jobs {
                    group.addTask {
                        do { return (id, .success(try await client.fetchReport())) }
                        catch { return (id, .failure(error)) }
                    }
                }
                for await (id, result) in group {
                    switch result {
                    case .success(let d):
                        newData[id] = d
                        newSuccess[id] = Date()
                    case .failure(let e):
                        newErrors[id] = explainError(e)
                    }
                }
            }
            guard let self else { return }
            self.apply(results: newData, errors: newErrors, success: newSuccess)
            WatchBridge.shared.sync()
            self.polling = false
            self.isLoading = false
        }
    }

    private func apply(results: [String: AgentData],
                       errors: [String: String],
                       success: [String: Date]) {
        for (id, d) in results {
            data[id] = d
            serverErrors[id] = nil
            lastSuccess[id] = success[id]
        }
        for (id, e) in errors {
            serverErrors[id] = e
        }
        // 聚合错误（对齐 Dart _tickAll）
        let errs = servers.compactMap { s -> String? in
            serverErrors[s.id].map { "\(s.name): \($0)" }
        }
        error = errs.isEmpty ? nil : errs.joined(separator: "\n")
    }

    /// 下拉刷新 / 顶部刷新
    func refresh() {
        error = nil
        for (id, client) in clients {
            Task { [weak self] in
                do {
                    let d = try await client.fetchReport()
                    self?.data[id] = d
                    self?.serverErrors[id] = nil
                    self?.lastSuccess[id] = Date()
                } catch {
                    self?.serverErrors[id] = explainError(error)
                }
                self?.refreshAggregateError()
                WatchBridge.shared.sync()
            }
        }
    }

    /// 单台重试（错误卡的重试按钮）
    func pollServer(_ s: MonitorServer) {
        pollServer(id: s.id)
    }

    /// 按 id 重试（手表 WatchBridge 消息用）
    func pollServer(id: String) {
        guard let client = clients[id] else { return }
        Task { [weak self] in
            do {
                let d = try await client.fetchReport()
                self?.data[id] = d
                self?.serverErrors[id] = nil
                self?.lastSuccess[id] = Date()
            } catch {
                self?.serverErrors[id] = explainError(error)
            }
            self?.refreshAggregateError()
            WatchBridge.shared.sync()
        }
    }

    func retryAll() {
        error = nil
        serverErrors = [:]
        polling = false
        tickAll()
    }

    /// 后台刷新用：跑完整一轮轮询，落地后回调（供 BGTask 交差）
    func backgroundPoll(completion: @escaping @MainActor () -> Void) {
        guard !polling else { completion(); return }
        polling = true
        let jobs: [(String, AgentClient)] = clients.map { ($0.key, $0.value) }
        Task { [weak self] in
            var newData: [String: AgentData] = [:]
            var newErrors: [String: String] = [:]
            var newSuccess: [String: Date] = [:]
            await withTaskGroup(of: (String, Result<AgentData, Error>).self) { group in
                for (id, client) in jobs {
                    group.addTask {
                        do { return (id, .success(try await client.fetchReport())) }
                        catch { return (id, .failure(error)) }
                    }
                }
                for await (id, result) in group {
                    switch result {
                    case .success(let d):
                        newData[id] = d
                        newSuccess[id] = Date()
                    case .failure(let e):
                        newErrors[id] = explainError(e)
                    }
                }
            }
            guard let self else { return }
            self.apply(results: newData, errors: newErrors, success: newSuccess)
            WatchBridge.shared.sync()
            self.polling = false
            completion()
        }
    }

    /// 清空所有错误显示（错误详情页「清空」按钮）
    func clearErrors() {
        error = nil
        serverErrors = [:]
    }

    private func refreshAggregateError() {
        let errs = servers.compactMap { s -> String? in
            serverErrors[s.id].map { "\(s.name): \($0)" }
        }
        error = errs.isEmpty ? nil : errs.joined(separator: "\n")
    }

    // MARK: - 增删改

    /// 新增 agent server（对齐 Dart addAgentServer）
    func addAgentServer(name: String, url: String, token: String, relayUrl: String? = nil) -> MonitorServer {
        let uri = URLComponents(string: url)
        let maxOrder = servers.reduce(0) { max($0, $1.sortOrder) }
        let s = MonitorServer(
            id: genId(name),
            name: name,
            host: uri?.host ?? "",
            port: uri?.port ?? ((uri?.scheme == "http") ? 80 : 443),
            https: uri?.scheme != "http",
            agentUrl: url,
            relayUrl: relayUrl,
            sortOrder: maxOrder + 1
        )
        clients[s.id] = AgentClient(endpoint: relayBase(s) ?? url, token: token)
        servers.append(s)
        tokens[s.id] = token
        TokenStore.save(id: s.id, token: token)
        saveServers()
        pollServer(s)
        return s
    }

    /// 更新连接信息：重建 client（对齐 Dart updateServer）
    func updateServer(id: String, name: String, url: String, token: String, relayUrl: String? = nil) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        var s = servers[idx]
        let uri = URLComponents(string: url)
        s.name = name
        s.host = uri?.host ?? s.host
        s.port = uri?.port ?? s.port
        s.https = uri?.scheme != "http"
        s.agentUrl = url
        s.relayUrl = relayUrl
        servers[idx] = s
        clients[id] = AgentClient(endpoint: relayBase(s) ?? url, token: token)
        tokens[id] = token
        TokenStore.save(id: id, token: token)
        saveServers()
        pollServer(s)
    }

    func deleteServer(id: String) {
        clients.removeValue(forKey: id)
        TokenStore.delete(id: id)
        servers.removeAll { $0.id == id }
        data.removeValue(forKey: id)
        serverErrors.removeValue(forKey: id)
        lastSuccess.removeValue(forKey: id)
        saveServers()
    }

    /// 拖拽排序持久化（对齐 Dart reorderServers：写入 sortOrder）
    func reorderServers(from oldIndex: Int, to newIndex: Int) {
        var list = orderedServers
        guard oldIndex >= 0, oldIndex < list.count else { return }
        var target = newIndex
        if target > list.count { target = list.count }
        if target > oldIndex { target -= 1 }
        if target == oldIndex { return }
        let item = list.remove(at: oldIndex)
        list.insert(item, at: target)
        for (i, s) in list.enumerated() {
            if let idx = servers.firstIndex(where: { $0.id == s.id }) {
                servers[idx].sortOrder = i
            }
        }
        saveServers()
    }

    /// 信任/取消信任证书后刷新设置页计数
    func refreshTrustedCertCount() {
        trustedCertCount = TrustStore.loadAll().count
    }

    // MARK: - 测试连接（TOFU capture 模式）

    func testAgent(url: String, token: String, relayUrl: String? = nil) async -> AgentTestResult {
        var probe = url
        if let relay = relayUrl, !relay.isEmpty {
            probe = relay.hasSuffix("/") ? String(relay.dropLast()) : relay
        }
        let client = AgentClient(endpoint: probe, token: token, captureMode: true)
        return await client.test()
    }

    // MARK: - disk alias / hidden 持久化（disk_config.json，对齐 v2.4.15+）

    func updateDiskConfig(id: String, aliases: [String: String]? = nil,
                          hidden: [String: Bool]? = nil, merge: Bool = false) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        var s = servers[idx]
        if let aliases {
            s.diskAliases = merge ? s.diskAliases.merging(aliases) { _, new in new } : aliases
        }
        if let hidden {
            s.hiddenDisks = merge ? s.hiddenDisks.merging(hidden) { _, new in new } : hidden
        }
        servers[idx] = s
        saveDiskConfig()
    }

    private var diskConfigURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.diskConfigFileName)
    }

    private func loadDiskConfig() async {
        guard let url = diskConfigURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            // 首次升级：老数据嵌在 server 列表 JSON 里 → 迁到文件
            migrateDiskConfigFromServerList()
            return
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let j = obj as? [String: Any] else { return }
        for i in servers.indices {
            guard let v = j[servers[i].id] as? [String: Any] else { continue }
            servers[i].diskAliases = (v["aliases"] as? [String: String]) ?? [:]
            servers[i].hiddenDisks = (v["hidden"] as? [String: Bool]) ?? [:]
        }
    }

    private func migrateDiskConfigFromServerList() {
        var out: [String: Any] = [:]
        for s in servers {
            if !s.diskAliases.isEmpty || !s.hiddenDisks.isEmpty {
                out[s.id] = ["aliases": s.diskAliases, "hidden": s.hiddenDisks]
            }
        }
        guard !out.isEmpty, let url = diskConfigURL,
              let data = try? JSONSerialization.data(withJSONObject: out) else { return }
        try? data.write(to: url)
    }

    @discardableResult
    private func saveDiskConfig() -> Bool {
        var out: [String: Any] = [:]
        for s in servers {
            if !s.diskAliases.isEmpty || !s.hiddenDisks.isEmpty {
                out[s.id] = ["aliases": s.diskAliases, "hidden": s.hiddenDisks]
            }
        }
        guard let url = diskConfigURL,
              let data = try? JSONSerialization.data(withJSONObject: out) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 服务器列表持久化

    private func loadServers() -> ([MonitorServer], [String: String]) {
        guard let raw = UserDefaults.standard.string(forKey: Self.serversKey),
              !raw.isEmpty, let jsonData = raw.data(using: .utf8) else {
            return ([], [:])
        }
        // 先用 JSONSerialization 抽 legacy 内嵌 token（迁移后剥离）
        var legacyTokens: [String: String] = [:]
        if let arr = (try? JSONSerialization.jsonObject(with: jsonData)) as? [[String: Any]] {
            for m in arr {
                if let id = m["id"] as? String, let tok = m["token"] as? String {
                    legacyTokens[id] = tok
                }
            }
        }
        do {
            let list = try JSONDecoder().decode([MonitorServer].self, from: jsonData)
            return (list, legacyTokens)
        } catch {
            // Bug #7 fix: 配置损坏要明示，不能静默吞掉
            self.error = "本地服务器配置损坏或被外部修改，已重置为空白。请重新添加服务器。"
            UserDefaults.standard.removeObject(forKey: Self.serversKey)
            return ([], legacyTokens)
        }
    }

    private func saveServers(stripLegacyTokens: Bool = false) {
        do {
            let data = try JSONEncoder().encode(servers)
            if let str = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(str, forKey: Self.serversKey)
            }
        } catch {
            print("[MonitorStore] saveServers failed: \(error)")
        }
    }

    /// id 冲突时加数字后缀（对齐 Dart _genId）
    private func genId(_ name: String) -> String {
        let base = name.lowercased()
            .map { ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "-" ? $0 : "-" }
        let baseId = base.isEmpty ? "srv-\(Int(Date().timeIntervalSince1970 * 1000))" : String(base)
        func taken(_ id: String) -> Bool {
            clients[id] != nil || servers.contains { $0.id == id }
        }
        if !taken(baseId) { return baseId }
        var i = 2
        while taken("\(baseId)-\(i)") { i += 1 }
        return "\(baseId)-\(i)"
    }
}
