// 机器列表页 —— 对齐 Flutter 版 lib/ios/ios_machines_page.dart。
//
// 卡片右侧只有状态徽章，不加箭头（点卡片直接进详情）。
// 排序：原生 List editMode 拖动（替代 Flutter 版手写的 iOS-Home-Screen 拖拽）。

import SwiftUI

struct MachinesView: View {
    @Environment(MonitorStore.self) private var store
    /// 点卡片进详情（程序化导航，避免 NavigationLink 自带箭头）
    var onOpenServer: (MonitorServer) -> Void = { _ in }
    var onEditServer: (MonitorServer) -> Void = { _ in }

    @State private var editMode = EditMode.inactive
    @State private var pendingDelete: MonitorServer?

    var body: some View {
        Group {
            if store.servers.isEmpty {
                EmptyView()
            } else if store.isAllFailed {
                ErrorFullView(message: store.error ?? "") {
                    store.retryAll()
                }
            } else {
                serverList
            }
        }
        .navigationTitle("总览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else if store.error != nil && !store.error!.isEmpty {
                    NavigationLink {
                        ErrorDetailsView()
                    } label: {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
        }
        .navigationDestination(for: MonitorServer.self) { server in
            DetailView(server: server)
        }
        .alert("删除服务器", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let s = pendingDelete { store.deleteServer(id: s.id) }
                pendingDelete = nil
            }
        } message: {
            if let s = pendingDelete {
                Text("确认删除「\(s.name)」？\n仅从本应用移除。")
            }
        }
    }

    // MARK: - 列表

    private var serverList: some View {
        List {
            ForEach(store.orderedServers) { server in
                // 点卡片直接进详情（Flutter 版同行为）；不用 NavigationLink，
                // 避免 iOS 27 列表导航行自带的 disclosure 箭头和玻璃底色
                ServerCard(
                    server: server,
                    data: store.agentFor(server),
                    error: store.errorFor(server),
                    status: computeStatus(store.lastSuccessFor(server)),
                    onRetry: { store.pollServer(server) }
                )
                .onTapGesture { onOpenServer(server) }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .contextMenu {
                    Button {
                        onOpenServer(server)
                    } label: {
                        Label("查看详情", systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        onEditServer(server)
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    if store.orderedServers.count > 1 {
                        Button {
                            withAnimation { editMode = .active }
                        } label: {
                            Label("排序", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    Button(role: .destructive) {
                        pendingDelete = server
                    } label: {
                        Label("删除服务器", systemImage: "trash")
                    }
                }
            }
            .onMove { source, destination in
                store.reorderServers(from: source.first ?? 0, to: destination)
            }

            // 底部「更新于」时间戳 chip
            if let t = store.lastSuccessAt {
                HStack {
                    Spacer()
                    Text("更新于 \(fmtTime(t))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.cardChipBackground, in: Capsule())
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 24, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
        .refreshable {
            store.refresh()
            try? await Task.sleep(for: .milliseconds(600))
        }
        .overlay(alignment: .top) {
            if editMode == .active {
                sortBanner
            }
        }
    }

    private var sortBanner: some View {
        HStack {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13))
                .foregroundStyle(Theme.primary)
            Text("排序模式：拖动调整顺序")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                withAnimation { editMode = .inactive }
            } label: {
                Text("完成")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Theme.primary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .cardSurface(cornerRadius: 14, stroke: Theme.primary.opacity(0.5))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - 服务器卡片（右侧只放状态徽章，不加箭头）

struct ServerCard: View {
    let server: MonitorServer
    let data: AgentData?
    let error: String?
    let status: ServerStatus
    var onRetry: () -> Void

    var body: some View {
        let isVps = data?.kind == "vps" || data?.xui != nil

        VStack(alignment: .leading, spacing: 10) {
            // 头部：NAS/VPS icon + 名字 + 状态徽章
            HStack(spacing: 8) {
                Image(systemName: isVps ? "globe" : "desktopcomputer")
                    .font(.system(size: 16))
                    .foregroundStyle(data == nil && error != nil ? Theme.danger : Theme.primary)
                Text(server.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                StatusPill(status: status)
            }

            if data == nil, let error, !error.isEmpty {
                // 错误态：错误信息 + 重试按钮
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "cloud.bolt")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.danger)
                        Text(error)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.danger)
                            .lineLimit(2)
                    }
                    Button(action: onRetry) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                            Text("重试")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            } else if data == nil {
                Text("暂无数据（首次拉取中）")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else if let hw = data?.hardware {
                cardBody(hw: hw)
            } else {
                Text("暂无硬件数据")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(16)
        .cardSurface(cornerRadius: 20)
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func cardBody(hw: Hardware) -> some View {
        let cpu = hw.cpu
        let mem = hw.memory
        let gpu = hw.gpu
        let disks = hw.disks ?? []
        let temp = cpu?.tempC ?? 0

        // CPU + 内存 横向用量条
        HStack(spacing: 12) {
            MiniUsageBar(
                label: "CPU",
                value: cpu.map { String(format: "%.1f%%", $0.percent) } ?? "—",
                percent: cpu?.percent ?? 0,
                color: cpu.map { usageColor($0.percent) } ?? Theme.textTertiary
            )
            MiniUsageBar(
                label: "内存",
                value: mem.map { String(format: "%.0f%%", $0.percent) } ?? "—",
                percent: mem?.percent ?? 0,
                color: mem.map { usageColor($0.percent) } ?? Theme.textTertiary
            )
        }

        // 温度 / GPU / 磁盘 / xui 客户端 mini chip
        HStack(spacing: 12) {
            MiniStat(icon: "thermometer", label: "温度",
                     value: temp > 0 ? String(format: "%.0f°C", temp) : "—",
                     color: temp > 0 ? tempColor(temp) : nil)
            if let gpu, gpu.hasUtil {
                MiniStat(icon: "gauge.medium", label: "GPU",
                         value: String(format: "%.0f%%", gpu.percent!),
                         color: usageColor(gpu.percent!))
            }
            if let gpu, gpu.hasTemp {
                MiniStat(icon: "thermometer", label: "显卡",
                         value: String(format: "%.0f°C", gpu.tempC!),
                         color: tempColor(gpu.tempC!))
            }
            if let first = disks.first {
                MiniStat(icon: "archivebox", label: "磁盘",
                         value: String(format: "%.0f%%", first.percent),
                         color: usageColor(first.percent))
            }
            if let xui = data?.xui {
                MiniStat(icon: "person.2", label: "客户端",
                         value: "\(xui.onlineCount)/\(xui.totalClients)",
                         color: Theme.primary)
            }
        }
    }
}

// MARK: - 小组件

struct StatusPill: View {
    let status: ServerStatus
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
            Text(status.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(status.color.opacity(0.4), lineWidth: 0.5)
        )
    }
}

struct MiniUsageBar: View {
    let label: String
    let value: String
    let percent: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .tracking(0.5)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.trackBackground)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geo.size.width * min(max(percent, 0), 100) / 100)
                }
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity)
    }
}

struct MiniStat: View {
    let icon: String
    let label: String
    let value: String
    var color: Color?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color ?? Theme.textTertiary)
            Text("\(label) \(value)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - 空状态 / 整页错误

struct EmptyView: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(LinearGradient(colors: [Theme.primary, Theme.primaryLight],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
            }
            Text("还没有服务器")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("点击底部 tab bar 的「添加」，添加你的第一台服务器")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorFullView: View {
    let message: String
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.bolt")
                .font(.system(size: 48))
                .foregroundStyle(Theme.danger)
            Text("连不上服务器")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13))
                    Text("重试")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(Theme.primary, in: Capsule())
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
