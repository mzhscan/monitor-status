// 手表总览页 —— 汇总计数 + 服务器列表（状态点 / CPU / 内存）。

import SwiftUI

struct WatchOverviewView: View {
    @Environment(WatchSession.self) private var session

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
                HStack(spacing: 6) {
                    statusDot(count: snap.onlineCount, color: .green, label: "在线")
                    if snap.stalledCount > 0 {
                        statusDot(count: snap.stalledCount, color: .yellow, label: "卡")
                    }
                    if snap.offlineCount > 0 {
                        statusDot(count: snap.offlineCount, color: .red, label: "离线")
                    }
                    Spacer()
                    Text(fmtClock(snap.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(snap.servers) { server in
                NavigationLink(value: server) {
                    row(server)
                }
            }
        }
    }

    private func row(_ s: WatchServer) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color(for: s.status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle(for: s))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func subtitle(for s: WatchServer) -> String {
        switch s.status {
        case "online", "stalled":
            var parts: [String] = []
            if let cpu = s.cpuPct { parts.append("CPU \(Int(cpu.rounded()))%") }
            if let mem = s.memPct { parts.append("内存 \(Int(mem.rounded()))%") }
            return parts.isEmpty ? "在线" : parts.joined(separator: " · ")
        case "offline":
            return s.secondsAgo >= 0 ? "离线 \(fmtAgo(s.secondsAgo))" : "离线"
        default:
            return "加载中…"
        }
    }

    private func statusDot(count: Int, color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(count)")
                .font(.system(size: 11, weight: .medium))
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
