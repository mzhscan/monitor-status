// 手表详情页 —— CPU/内存表盘 + 负载/运行时长 + 开机上下行总量 + xui 流量 + 重试。

import SwiftUI

struct WatchDetailView: View {
    @Environment(WatchSession.self) private var session
    let server: WatchServer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if server.status == "offline" || server.status == "loading" {
                    errorBlock
                }
                if server.cpuPct != nil || server.memPct != nil {
                    gauges
                }
                infoRows
                if server.rxBytes != nil || server.txBytes != nil {
                    trafficRows
                }
                if server.isVps {
                    xuiBlock
                }
                if server.status != "online" {
                    Button {
                        session.retry(id: server.id)
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 分块

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: server.isVps ? "globe" : "desktopcomputer")
                .font(.system(size: 12))
                .foregroundStyle(.pink)
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color(for: server.status))
            Spacer()
        }
    }

    private var statusText: String {
        switch server.status {
        case "online": return "在线"
        case "stalled": return "卡 \(server.secondsAgo)s"
        case "offline": return server.secondsAgo >= 0 ? "离线 \(fmtAgo(server.secondsAgo))" : "离线"
        default: return "加载中"
        }
    }

    @ViewBuilder
    private var errorBlock: some View {
        if let err = server.error, !err.isEmpty {
            Text(err)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    private var gauges: some View {
        HStack(spacing: 8) {
            if let cpu = server.cpuPct {
                Gauge(value: cpu, in: 0...100) {
                    Text("CPU")
                } currentValueLabel: {
                    Text("\(Int(cpu.rounded()))")
                }
                .gaugeStyle(.accessoryCircular)
                .tint(gaugeColor(cpu))
            }
            if let mem = server.memPct {
                Gauge(value: mem, in: 0...100) {
                    Text("内存")
                } currentValueLabel: {
                    Text("\(Int(mem.rounded()))")
                }
                .gaugeStyle(.accessoryCircular)
                .tint(gaugeColor(mem))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var infoRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let t = server.cpuTemp, t > 0 {
                kv("温度", String(format: "%.0f°C", t), color: t >= 80 ? .red : (t >= 65 ? .yellow : .green))
            }
            if let load = server.load1 {
                kv("负载", String(format: "%.2f", load))
            }
            if let up = server.uptime, !up.isEmpty {
                kv("运行", up)
            }
        }
    }

    private var trafficRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let rx = server.rxBytes {
                trafficRow("下行", bytes: rx, icon: "arrow.down.circle", color: .cyan)
            }
            if let tx = server.txBytes {
                trafficRow("上行", bytes: tx, icon: "arrow.up.circle", color: .orange)
            }
        }
    }

    private func trafficRow(_ label: String, bytes: Int64, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(fmtBytes(bytes))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    private var xuiBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let online = server.xuiOnline, let total = server.xuiTotalClients {
                kv("xui 在线", "\(online)/\(total)", color: .pink)
            }
            if let gb = server.xuiTotalGb {
                kv("累计流量", fmtGb(gb), color: .pink)
            }
            if let t72 = server.traffic72hGb, t72 > 0 {
                kv("72h 流量", fmtGb(t72), color: .pink)
            }
        }
    }

    // MARK: - 小件

    private func kv(_ k: String, _ v: String, color: Color = .primary) -> some View {
        HStack(spacing: 4) {
            Text(k)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(v)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
    }

    private func gaugeColor(_ pct: Double) -> Color {
        if pct >= 85 { return .red }
        if pct >= 60 { return .yellow }
        return .green
    }
}
