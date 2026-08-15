// 设置页 —— 对齐 Flutter 版 ios_settings_page.dart：
// 检查更新 / 项目主页 / 高级排错（受信任证书 + 清空数据）/ 错误入口 / 信息。

import SwiftUI

struct SettingsView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.openURL) private var openURL

    @State private var showResetConfirm = false
    @State private var showResetDone = false

    /// 任意错误存在 → 显示错误入口（对齐 IOSErrorDetailsPage.hasErrors）
    private var hasErrors: Bool {
        if let e = store.error, !e.isEmpty { return true }
        return store.servers.contains { s in
            if let e = store.errorFor(s), !e.isEmpty { return true }
            return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("检查更新")
                CheckUpdateCard()

                sectionTitle("项目主页").padding(.top, 12)
                linkRow(icon: "chevron.left.forwardslash.chevron.right",
                        title: "GitHub 仓库",
                        subtitle: "github.com/mzhscan/monitor-status") {
                    openURL(CheckUpdate.releasePage)
                }
                linkRow(icon: "book",
                        title: "部署文档 (README)",
                        subtitle: "一键部署 agent / 添加服务器步骤") {
                    openURL(CheckUpdate.readmeUrl)
                }

                sectionTitle("高级 / 排错").padding(.top, 12)
                TrustedCertsCard()
                resetCard.padding(.top, 8)

                if hasErrors {
                    sectionTitle("错误").padding(.top, 12)
                    NavigationLink {
                        ErrorDetailsView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.danger)
                            Text("错误详情")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("有错误")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.danger)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Theme.danger.opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 8))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .cardSurface(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                }

                sectionTitle("信息").padding(.top, 12)
                infoCard

                Text("MIT License · mzhscan")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        // 背景渐变统一由 RootView 铺一层
        .scrollContentBackground(.hidden)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认清空？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { doResetAll() }
        } message: {
            Text("将删除本机所有已添加的服务器和受信任的证书。\nagent 本身不受影响，重启后还可以重新添加。")
        }
        .alert("已清空所有本地数据", isPresented: $showResetDone) {
            Button("好", role: .cancel) {}
        }
    }

    // MARK: - 组件

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 4)
    }

    private func linkRow(icon: String, title: String, subtitle: String,
                         onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            .cardSurface(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    /// 清空所有数据入口（红色危险操作）
    private var resetCard: some View {
        Button {
            showResetConfirm = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("清空所有数据")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                    Text("删除所有 agent 配置 + 信任的证书（不可恢复）")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(14)
            .cardSurface(cornerRadius: 16, stroke: Theme.danger.opacity(0.25))
        }
        .buttonStyle(.plain)
    }

    private func doResetAll() {
        for s in Array(store.servers) {
            store.deleteServer(id: s.id)
        }
        for url in TrustStore.loadAll().keys {
            TrustStore.untrust(origin: url)
        }
        store.refreshTrustedCertCount()
        showResetDone = true
    }

    private var infoCard: some View {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return VStack(alignment: .leading, spacing: 8) {
            infoRow("版本", "v\(store.appVersion) (\(build))")
            infoRow("机器数", "\(store.servers.count)")
            infoRow("受信任证书", "\(store.trustedCertCount)")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 80, alignment: .leading)
            Text(v)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
    }
}

// MARK: - 检查更新卡

struct CheckUpdateCard: View {
    @State private var result: CheckUpdateResult?
    @State private var busy = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if busy {
                    ProgressView().tint(Theme.primary)
                        .frame(width: 20)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("检查新版本")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(result?.summary ?? "点击从 GitHub 拉取最新 release")
                        .font(.system(size: 11))
                        .foregroundStyle(summaryColor)
                }
                Spacer()
                Button(action: check) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            if let r = result, r.isNewer {
                Rectangle()
                    .fill(Theme.trackBackground)
                    .frame(height: 1)
                    .padding(.vertical, 10)
                Text("新版本: v\(r.latestTag ?? "")")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let body = r.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(4)
                        .padding(.top, 4)
                }
                Button("打开 release") {
                    openURL(CheckUpdate.releasePage)
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.primary)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
    }

    private var summaryColor: Color {
        if result?.isError == true { return Theme.danger }
        if result?.isNewer == true { return Theme.warning }
        return Theme.textTertiary
    }

    private func check() {
        busy = true
        result = nil
        Task {
            let r = await CheckUpdate.fetchLatest()
            result = r
            busy = false
        }
    }
}

// MARK: - 受信任证书卡（可展开 + 单条删除）

struct TrustedCertsCard: View {
    @Environment(MonitorStore.self) private var store
    @State private var trusted: [String: String] = [:]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("受信任的证书")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text(trusted.isEmpty
                             ? "无（说明服务器都用的公共 CA 证书）"
                             : "已为 \(trusted.count) 个 agent 信任证书")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if expanded && !trusted.isEmpty {
                Rectangle()
                    .fill(Theme.trackBackground)
                    .frame(height: 1)
                    .padding(.vertical, 4)
                ForEach(Array(trusted.keys).sorted(), id: \.self) { key in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textPrimary)
                            Text(trusted[key] ?? "")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            TrustStore.untrust(origin: key)
                            store.refreshTrustedCertCount()
                            trusted = TrustStore.loadAll()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.danger)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
        .onAppear { trusted = TrustStore.loadAll() }
    }
}
