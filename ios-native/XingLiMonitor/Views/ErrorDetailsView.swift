// 错误详情页 —— 对齐 Flutter 版 ios_error_details_page.dart：
// 顶部概览卡（聚合错误 + 最近成功时间）→ 每台出错 server 一张卡（URL +
// 最后响应时间 + 错误 + 单台重试）→ 底部「重试全部」。toolbar「清空」。

import SwiftUI

struct ErrorDetailsView: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summaryCard
                perServerCards
                retryAllButton
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        // 背景渐变统一由 RootView 铺一层
        .scrollContentBackground(.hidden)
        .navigationTitle("错误详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("清空") { store.clearErrors() }
                    .foregroundStyle(Theme.primary)
            }
        }
    }

    // MARK: - 概览卡

    private var hasAggregate: Bool {
        if let e = store.error, !e.isEmpty { return true }
        return false
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: hasAggregate
                      ? "exclamationmark.triangle"
                      : "checkmark.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(hasAggregate ? Theme.danger : Theme.success)
                Text(hasAggregate ? "总体异常" : "当前无异常")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(hasAggregate ? Theme.danger : Theme.success)
                Spacer()
                if let t = store.lastSuccessAt {
                    Text("最近成功：\(fmtTime(t))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if hasAggregate, let err = store.error {
                Text(err)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.danger.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.danger.opacity(0.4), lineWidth: 0.5)
                    )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
    }

    // MARK: - 每台出错 server 的卡

    private var errorServers: [(MonitorServer, String)] {
        store.orderedServers.compactMap { s in
            if let e = store.errorFor(s), !e.isEmpty { return (s, e) }
            return nil
        }
    }

    @ViewBuilder
    private var perServerCards: some View {
        let list = errorServers
        if !list.isEmpty {
            Text("服务器详情")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 4)
                .padding(.top, 4)
            ForEach(list, id: \.0.id) { s, err in
                serverCard(s, err)
            }
        }
    }

    private func serverCard(_ s: MonitorServer, _ err: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(s.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button {
                    store.pollServer(s)
                } label: {
                    Text("重试")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Theme.primary.opacity(0.18),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            if let url = s.agentUrl, !url.isEmpty {
                Text(url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            if let last = store.lastSuccessFor(s) {
                let sa = Int(Date().timeIntervalSince(last).rounded())
                if sa > 0 {
                    Text("最后一次响应：\(sa) 秒前")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Text(err)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Theme.danger.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.danger.opacity(0.4), lineWidth: 0.5)
                )
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
    }

    // MARK: - 重试全部

    private var retryAllButton: some View {
        Button {
            store.retryAll()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15))
                Text("重试全部")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Theme.primary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }
}
