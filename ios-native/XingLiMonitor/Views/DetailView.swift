// 服务器详情页 —— 对齐 Flutter 版 lib/ios/ios_detail_page.dart 的信息密度：
// 头部（NAS/VPS + 状态 + uptime）→ 资源占用 → 硬盘（alias/隐藏编辑）→
// 系统服务 → 3X-UI 客户端（3 metric + 实时总流量 + inbounds + 客户端表）。

import SwiftUI

/// 字节数 → 人类可读（B/KB/MB/GB/TB）
func formatBytes(_ b: Int) -> String {
    let v = Double(b)
    if v < 1024 { return "\(b) B" }
    if v < 1024 * 1024 { return String(format: "%.1f KB", v / 1024) }
    if v < 1024 * 1024 * 1024 { return String(format: "%.1f MB", v / 1024 / 1024) }
    if v < 1024 * 1024 * 1024 * 1024 { return String(format: "%.2f GB", v / 1024 / 1024 / 1024) }
    return String(format: "%.2f TB", v / 1024 / 1024 / 1024 / 1024)
}

struct DetailView: View {
    @Environment(MonitorStore.self) private var store
    let server: MonitorServer

    var body: some View {
        ScrollView {
            if let d = store.agentFor(server) {
                content(d)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
            } else if let err = store.errorFor(server) {
                ErrorFullView(message: err) {
                    store.pollServer(server)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("首次拉取中…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            }
        }
        // 背景渐变统一由 RootView 铺一层（各页各自铺会导致拉伸区间不一致）
        .scrollContentBackground(.hidden)
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            store.pollServer(server)
            try? await Task.sleep(for: .milliseconds(600))
        }
    }

    @ViewBuilder
    private func content(_ d: AgentData) -> some View {
        let status = computeStatus(store.lastSuccessFor(server))
        let isVps = d.kind == "vps" || d.xui != nil
        let hw = d.hardware
        let disks = hw?.disks ?? []

        VStack(spacing: 16) {
            header(d, status, isVps)
            resourceSection(hw, disks)
            if !disks.isEmpty {
                disksSection(disks)
            }
            if !d.services.isEmpty {
                servicesSection(d.services)
            }
            if let xui = d.xui, !xui.clients.isEmpty {
                XuiSection(xui: xui)
            }
            if let t = store.lastSuccessFor(server) {
                Text("更新于 \(fmtTime(t))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - 头部

    private func header(_ d: AgentData, _ status: ServerStatus, _ isVps: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [Theme.primary, Theme.primaryLight],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                    Image(systemName: isVps ? "globe" : "desktopcomputer")
                        .font(.system(size: 19))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name.isEmpty ? server.name : d.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(isVps ? "VPS 主机" : "NAS / 主机")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                StatusPill(status: status)
            }
            // NAS/VPS chip + Agent chip + uptime
            HStack(spacing: 8) {
                chip(icon: isVps ? "cloud" : "archivebox",
                     text: isVps ? "VPS" : "NAS",
                     color: isVps ? Theme.info : Theme.success)
                chip(icon: "bolt", text: "Agent", color: Theme.primary)
                if let uptime = d.hardware?.uptime, !uptime.isEmpty {
                    chip(icon: "clock", text: uptime, color: Theme.success)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .cardSurface(cornerRadius: 20)
    }

    private func chip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.4), lineWidth: 0.5))
    }

    // MARK: - 资源占用

    @ViewBuilder
    private func resourceSection(_ hw: Hardware?, _ disks: [DiskEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("资源占用")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .tracking(0.5)

            if let cpu = hw?.cpu {
                resourceBar("CPU", cpu.percent, hint: cpu.hasModel ? cpu.model : nil)
            }
            if let mem = hw?.memory {
                resourceBar("内存", mem.percent,
                            hint: String(format: "%.1f / %.1f GB", mem.usedGb, mem.totalGb))
            }
            if let first = disks.first {
                resourceBar("磁盘", first.percent,
                            hint: String(format: "%.1f / %.0f GB", first.usedGb, first.totalGb))
            }

            // load / network mini KV
            let load = hw?.load
            HStack {
                miniKV("Load 1m", load.map { String(format: "%.2f", $0.l1) } ?? "—")
                miniKV("Load 5m", load.map { String(format: "%.2f", $0.l5) } ?? "—")
                miniKV("Load 15m", load.map { String(format: "%.2f", $0.l15) } ?? "—")
            }
            HStack {
                miniKV("接收", formatBytes(hw?.network?.rxBytes ?? 0))
                miniKV("发送", formatBytes(hw?.network?.txBytes ?? 0))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 20)
    }

    private func resourceBar(_ label: String, _ pct: Double, hint: String?) -> some View {
        let color = usageColor(pct)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(String(format: "%.1f%%", pct))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.trackBackground)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geo.size.width * min(max(pct, 0), 100) / 100)
                }
            }
            .frame(height: 8)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func miniKV(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    // MARK: - 硬盘（alias / 隐藏编辑）

    @State private var editingDisk: DiskEntry?

    private func disksSection(_ disks: [DiskEntry]) -> some View {
        // 拿最新的 server（diskAliases 可能被编辑过）
        let current = store.servers.first { $0.id == server.id } ?? server
        let visible = disks.filter { current.hiddenDisks[$0.mount] != true }
        let hiddenCount = disks.count - visible.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("硬盘")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)
                Spacer()
                Text(hiddenCount > 0
                     ? "\(visible.count) 块 / 已隐藏 \(hiddenCount)"
                     : "\(visible.count) 块")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            if visible.isEmpty {
                Text("所有硬盘都已隐藏，点任意盘恢复")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, disk in
                    DiskRow(disk: disk, alias: current.diskAliases[disk.mount]) {
                        editingDisk = disk
                    }
                }
            }
            // 已隐藏的盘也给入口（恢复显示）
            if hiddenCount > 0 {
                ForEach(Array(disks.filter { current.hiddenDisks[$0.mount] == true }.enumerated()),
                        id: \.offset) { _, disk in
                    Button {
                        editingDisk = disk
                    } label: {
                        HStack {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 11))
                            Text("\(diskDisplayName(disk, alias: current.diskAliases[disk.mount]))（已隐藏，点按恢复）")
                                .font(.system(size: 12))
                            Spacer()
                        }
                        .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 20)
        .sheet(item: $editingDisk) { disk in
            EditDiskSheet(serverId: server.id, disk: disk)
                .presentationDetents([.height(280)])
        }
    }

    private func diskDisplayName(_ disk: DiskEntry, alias: String?) -> String {
        if let alias, !alias.isEmpty { return alias }
        if !disk.name.isEmpty { return disk.name }
        let mountLeaf = disk.mount == "/" ? "系统盘" : String(disk.mount.split(separator: "/").last ?? "")
        return mountLeaf.isEmpty ? disk.device : mountLeaf
    }
    // MARK: - 系统服务

    private func servicesSection(_ services: [ServiceEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("系统服务")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .tracking(0.5)
            ForEach(Array(services.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 8) {
                    Circle()
                        .fill(serviceColor(s.status))
                        .frame(width: 6, height: 6)
                    Text(s.name)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(translateStatus(s.status))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(serviceColor(s.status))
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 20)
    }

    private func translateStatus(_ s: String) -> String {
        switch s {
        case "active": return "运行中"
        case "inactive": return "未运行"
        case "failed": return "已失败"
        case "activating": return "启动中"
        case "deactivating": return "停止中"
        case "reloading": return "重载中"
        case "maintenance": return "维护中"
        default: return s.isEmpty ? "未知" : s
        }
    }

    private func serviceColor(_ status: String) -> Color {
        switch status {
        case "active": return Theme.success
        case "failed", "inactive": return Theme.danger
        default: return Theme.textTertiary
        }
    }
}

// MARK: - 硬盘行

struct DiskRow: View {
    let disk: DiskEntry
    let alias: String?
    var onTap: () -> Void

    private var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        if !disk.name.isEmpty { return disk.name }
        let mountLeaf = disk.mount == "/" ? "系统盘" : String(disk.mount.split(separator: "/").last ?? "")
        return mountLeaf.isEmpty ? disk.device : mountLeaf
    }

    var body: some View {
        let color = usageColor(disk.percent)
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(displayName.isEmpty ? "(未挂载)" : displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if disk.hasTemp, let t = disk.tempC {
                        Image(systemName: "thermometer")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                        Text(String(format: "%.0f°C", t))
                            .font(.system(size: 11))
                            .foregroundStyle(tempColor(t))
                        Spacer().frame(width: 10)
                    }
                    Text(String(format: "%.0f%%", disk.percent))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(color)
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 2)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.trackBackground)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color)
                            .frame(width: geo.size.width * min(max(disk.percent, 0), 100) / 100)
                    }
                }
                .frame(height: 8)
                HStack(spacing: 12) {
                    Text(String(format: "%.1f / %.1f GB", disk.usedGb, disk.totalGb))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    if !disk.mount.isEmpty && disk.mount != "/\(displayName)" {
                        Text("挂载 \(disk.mount)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if !disk.device.isEmpty {
                        Text(disk.device)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }
}

// MARK: - 编辑硬盘 sheet（alias + 隐藏，对齐 _EditDiskSheet）

struct EditDiskSheet: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let serverId: String
    let disk: DiskEntry

    @State private var alias: String = ""
    @State private var hidden: Bool = false

    var body: some View {
        let server = store.servers.first { $0.id == serverId }
        NavigationStack {
            Form {
                Section {
                    TextField("硬盘别名（留空用默认名）", text: $alias)
                    Toggle("隐藏此硬盘", isOn: $hidden)
                        .tint(Theme.primary)
                } header: {
                    Text(disk.mount.isEmpty ? disk.device : disk.mount)
                } footer: {
                    Text(String(format: "%.1f / %.1f GB · %.0f%%",
                                disk.usedGb, disk.totalGb, disk.percent))
                }
            }
            .navigationTitle("编辑硬盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updateDiskConfig(
                            id: serverId,
                            aliases: [disk.mount: alias.trimmingCharacters(in: .whitespaces)],
                            hidden: [disk.mount: hidden],
                            merge: true
                        )
                        dismiss()
                    }
                }
            }
            .onAppear {
                alias = server?.diskAliases[disk.mount] ?? ""
                hidden = server?.hiddenDisks[disk.mount] == true
            }
        }
    }
}

// MARK: - 3X-UI section

enum XuiClientSort { case total, down, up }

struct XuiSection: View {
    let xui: XuiInfo
    @State private var sort: XuiClientSort = .total

    var body: some View {
        let sorted = sortedClients(xui.clients)

        VStack(alignment: .leading, spacing: 10) {
            // 标题
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.primary)
                Text("3X-UI 客户端")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            // 3 彩色 metric：在线 / 下行 / 上行
            HStack(spacing: 8) {
                xuiMetric(icon: "circle.fill", label: "在线",
                          value: "\(xui.onlineCount)/\(xui.totalClients)", color: Theme.success)
                xuiMetric(icon: "arrow.down", label: "下行",
                          value: fmtGb(xui.totalDownGb), color: Theme.info)
                xuiMetric(icon: "arrow.up", label: "上行",
                          value: fmtGb(xui.totalUpGb), color: Theme.primary)
            }

            // 实时总流量卡
            if let inbound = xui.inboundTotal {
                realTimeCard(inbound)
            }

            // Inbounds 列表
            if !xui.inbounds.isEmpty {
                Text("入站")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
                ForEach(Array(xui.inbounds.enumerated()), id: \.offset) { _, ib in
                    inboundRow(ib)
                }
            }

            // 客户端列表（表头可排序）
            if !xui.clients.isEmpty {
                Text("客户端")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
                clientHeader
                ForEach(Array(sorted.enumerated()), id: \.offset) { _, c in
                    clientRow(c)
                }
            }

            // 底部说明
            if xui.observedAt > 0 {
                Text("数据采集于 \(formatObservedAt(xui.observedAt)) · 3x-ui 客户端流量需断开时才更新（滞后 20+ 分钟）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(2)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 20)
    }

    private func sortedClients(_ clients: [XuiClient]) -> [XuiClient] {
        clients.sorted { a, b in
            switch sort {
            case .total: return a.totalGb > b.totalGb
            case .down: return a.downGb > b.downGb
            case .up: return a.upGb > b.upGb
            }
        }
    }

    private func xuiMetric(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(color.opacity(0.85))
                Text(value)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.3), lineWidth: 0.5))
    }

    private func realTimeCard(_ total: InboundTotal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.info)
                Text("VPS 主机总流量")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.info)
                Spacer()
                Text("\(total.inboundsCount) 个入口")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.success)
                    Text(fmtGb(total.downGb))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primary)
                    Text(fmtGb(total.upGb))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(
            LinearGradient(colors: [Theme.info.opacity(0.10), Theme.info.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.info.opacity(0.2), lineWidth: 0.5))
    }

    private func inboundRow(_ ib: XuiInbound) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ib.enable ? Theme.success : Theme.textTertiary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(ib.remark.isEmpty ? ":\(ib.port)" : ib.remark)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
            Text("↓\(fmtGb(ib.downGb))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.info)
            Text("↑\(fmtGb(ib.upGb))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.primary)
        }
        .padding(.vertical, 4)
    }

    // 表头（总计/下行/上行 可点击排序）
    private var clientHeader: some View {
        HStack {
            Text("客户端")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
            sortHeader("总计", .total)
            sortHeader("下行", .down)
            sortHeader("上行", .up)
            Text("72h")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 52, alignment: .trailing)
            Text("最近活跃")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    private func sortHeader(_ label: String, _ s: XuiClientSort) -> some View {
        let active = sort == s
        return Button {
            sort = s
        } label: {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 10.5, weight: active ? .bold : .semibold))
                    .foregroundStyle(active ? Theme.primary : Theme.textTertiary)
                if active {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.primary)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 48, alignment: .trailing)
    }

    private func clientRow(_ c: XuiClient) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(c.online ? Theme.success : (c.enable ? Theme.warning : Color(.systemGray4)))
                .frame(width: 6, height: 6)
            Text(c.email)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(fmtGb(c.totalGb))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 48, alignment: .trailing)
            Text(fmtGb(c.downGb))
                .font(.system(size: 11))
                .foregroundStyle(Theme.info)
                .frame(width: 48, alignment: .trailing)
            Text(fmtGb(c.upGb))
                .font(.system(size: 11))
                .foregroundStyle(Theme.primary)
                .frame(width: 48, alignment: .trailing)
            Text(c.traffic72hGb == nil ? "—" : fmtGb(c.traffic72hGb!))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(c.traffic72hGb == nil ? Color(.systemGray3) : Theme.textSecondary)
                .frame(width: 52, alignment: .trailing)
            Text(formatLastOnline(c.lastOnline))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(c.online ? Theme.success : Theme.textTertiary)
                .lineLimit(1)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.primaryLight.opacity(0.2)).frame(height: 0.5)
        }
    }

    private func formatObservedAt(_ sec: Int) -> String {
        guard sec > 0 else { return "—" }
        return fmtTime(Date(timeIntervalSince1970: TimeInterval(sec)))
    }

    /// "X秒/分/时/天 前"（对齐 Dart _formatLastOnline；参数是 unix ms）
    private func formatLastOnline(_ ms: Int) -> String {
        if ms <= 0 { return "从未" }
        let sec = Int((Double(Date().timeIntervalSince1970 * 1000) - Double(ms)) / 1000)
        if sec < 0 { return "刚刚" }
        if sec < 60 { return "\(sec)秒前" }
        if sec < 3600 { return "\(sec / 60)分前" }
        if sec < 86400 { return "\(sec / 3600)时前" }
        return "\(sec / 86400)天前"
    }
}
