// 手表总览页 —— 状态卡片墙：顶部汇总卡 + 每台服务器一张圆角卡片
//（状态色竖条 / 设备图标 / CPU·内存迷你条 / 开机流量）。

import SwiftUI

struct WatchOverviewView: View {
    @Environment(WatchSession.self) private var session

    /// 卡片实心深灰底（对齐 iPhone 深色主题 #1C1C1E，手表恒为深色）
    private let cardFill = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        NavigationStack {
            Group {
                if let snap = session.snapshot {
                    if snap.servers.isEmpty {
                        emptyHint("还没有服务器", sub: "请在 iPhone 上添加")
                    } else {
                        serverList(snap)
                    }
                } else {
                    emptyHint(session.waiting ? "同步中…" : "等待 iPhone 数据",
                              sub: "确认 iPhone 版星黎监控正在运行")
                }
            }
            .navigationTitle("星黎监控")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        session.requestRefresh()
                    } label: {
                        if session.waiting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .navigationDestination(for: WatchServer.self) { server in
                WatchDetailView(server: server)
            }
        }
    }

    private func serverList(_ snap: WatchSnapshot) -> some View {
        List {
            Section {
                summaryCard(snap)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 4, trailing: 2))
            }
            ForEach(snap.servers) { server in
                NavigationLink(value: server) {
                    serverCard(server)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2))
            }
        }
        .listStyle(.plain)
    }

    // MARK: - 卡片

    /// 顶部汇总卡：在线数大字 + 离线计数 + 更新时间
    private func summaryCard(_ snap: WatchSnapshot) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text("\(snap.onlineCount)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(overallColor(snap))
            Text("/\(snap.servers.count) 在线")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if snap.offlineCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(.red).frame(width: 5, height: 5)
                        Text("离线 \(snap.offlineCount)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.red)
                    }
                }
                Text(fmtClock(snap.updatedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 13).fill(cardFill))
    }

    /// 单台服务器卡：左侧状态竖条 + 图标 + 名称/状态胶囊 + 指标
    private func serverCard(_ s: WatchServer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.isVps ? "globe" : "desktopcomputer")
                .font(.system(size: 14))
                .foregroundStyle(.pink)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(s.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    statusPill(s)
                }
                if s.status == "online" || s.status == "stalled" {
                    metricBars(s)
                    trafficLine(s)
                } else if s.status == "offline", let err = s.error, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.07), lineWidth: 1))
        .overlay(alignment: .leading) {
            // 状态色竖条（跟随卡片高度）
            Capsule()
                .fill(color(for: s.status))
                .frame(width: 3)
                .padding(.vertical, 9)
                .padding(.leading, 3)
        }
    }

    // MARK: - 卡内小件

    @ViewBuilder
    private func metricBars(_ s: WatchServer) -> some View {
        VStack(spacing: 3) {
            if let cpu = s.cpuPct { metricBar("CPU", pct: cpu) }
            if let mem = s.memPct { metricBar("内存", pct: mem) }
        }
    }

    private func metricBar(_ label: String, pct: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.gray.opacity(0.25))
                    Capsule()
                        .fill(barColor(pct))
                        .frame(width: max(2, geo.size.width * pct / 100))
                }
            }
            .frame(height: 4)
            Text("\(Int(pct.rounded()))%")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(barColor(pct))
                .frame(width: 24, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func trafficLine(_ s: WatchServer) -> some View {
        if s.rxBytes != nil || s.txBytes != nil {
            HStack(spacing: 8) {
                if let rx = s.rxBytes {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 7, weight: .bold))
                        Text(fmtBytes(rx))
                    }
                    .foregroundStyle(.cyan)
                }
                if let tx = s.txBytes {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 7, weight: .bold))
                        Text(fmtBytes(tx))
                    }
                    .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 9, weight: .medium))
        }
    }

    private func statusPill(_ s: WatchServer) -> some View {
        let c = color(for: s.status)
        return Text(pillText(s))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(c)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.16)))
    }

    private func pillText(_ s: WatchServer) -> String {
        switch s.status {
        case "online": return "在线"
        case "stalled": return "卡 \(s.secondsAgo)s"
        case "offline": return s.secondsAgo >= 0 ? "离线 \(fmtAgo(s.secondsAgo))" : "离线"
        default: return "加载中"
        }
    }

    private func emptyHint(_ title: String, sub: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(sub)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - 共享小工具（手表端）

func color(for status: String) -> Color {
    switch status {
    case "online": return .green
    case "stalled": return .yellow
    case "offline": return .red
    default: return .gray
    }
}

/// 用量百分比 → 绿/黄/红
func barColor(_ pct: Double) -> Color {
    if pct >= 85 { return .red }
    if pct >= 60 { return .yellow }
    return .green
}

/// 汇总卡大字颜色：全绿 → 绿，有离线 → 红，其余 → 黄
func overallColor(_ snap: WatchSnapshot) -> Color {
    if snap.offlineCount > 0 { return .red }
    if snap.onlineCount == snap.servers.count { return .green }
    return .yellow
}

func fmtClock(_ t: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: t)
}

/// 秒数 → "12s" / "3m" / "2h"
func fmtAgo(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h"
}

func fmtGb(_ gb: Double) -> String {
    if gb < 1 { return String(format: "%.0fMB", gb * 1024) }
    if gb < 100 { return String(format: "%.1fGB", gb) }
    return String(format: "%.0fGB", gb)
}

/// 字节数 → "12MB" / "3.2GB" / "1.5TB"（开机累计流量用）
func fmtBytes(_ b: Int64) -> String {
    let tb = Double(b) / 1024 / 1024 / 1024 / 1024
    if tb >= 1 { return String(format: "%.2fTB", tb) }
    let gb = tb * 1024
    if gb >= 100 { return String(format: "%.0fGB", gb) }
    if gb >= 1 { return String(format: "%.1fGB", gb) }
    let mb = gb * 1024
    if mb >= 1 { return String(format: "%.0fMB", mb) }
    return String(format: "%.0fKB", mb * 1024)
}
