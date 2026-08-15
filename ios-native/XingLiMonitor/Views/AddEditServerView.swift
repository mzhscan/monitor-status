// 添加 / 编辑服务器页 —— 对齐 Flutter 版 ios_add_server_page.dart。
//
//   - 5 字段（name / host / port / https 切换 / token）
//   - URL 实时预览
//   - 测试连接按钮 + 测试结果
//   - TOFU 自签证书信任弹框（captureMode 拿到指纹 → 确认 → trust → 重测）
//   - 编辑模式：editing 非空，token 留空用旧 token
//   - 新增模式：token 必填

import SwiftUI

struct AddEditServerView: View {
    @Environment(MonitorStore.self) private var store
    /// 非空 = 编辑模式
    let editing: MonitorServer?
    /// 保存/取消后通知父切回原 tab
    let onClose: () -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var useHttps = true
    @State private var token = ""
    @State private var obscureToken = true
    @State private var busy = false
    @State private var testResult: String?
    @State private var testOk = false

    // TOFU 待确认证书（测试连接捕获）
    @State private var pendingUrl = ""
    @State private var pendingToken = ""
    @State private var pendingFingerprint: String?
    @State private var showTrustDialog = false

    private var isEdit: Bool { editing != nil }

    private var scheme: String { useHttps ? "https" : "http" }

    /// 实时 URL 预览（对齐 Dart _fullUrl）
    private var fullUrl: String {
        let h = host.trimmingCharacters(in: .whitespaces)
        let p = port.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return "\(scheme)://（域名/IP）:\(p.isEmpty ? "端口" : p)" }
        return "\(scheme)://\(h):\(p.isEmpty ? "?" : p)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("每台被监控的服务器都需要先安装 agent（一键脚本见 GitHub）。\n填 agent 暴露的域名/IP + 端口 + 协议 + token。\n内网机器：填公网 relay 的域名/端口 + reverse-agent push 用的 token。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(3)
                    .padding(.top, 4)

                formCard
                urlPreview

                if let r = testResult {
                    testResultBox(r)
                }

                Button(action: doTest) {
                    Group {
                        if busy {
                            ProgressView().tint(Theme.primary)
                        } else {
                            Text("测试连接")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.primary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Theme.primary.opacity(0.35), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .padding(.top, 4)

                Text("说明")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
                Text("• Token 跟 Android app 配的是同一个\n• 公网机器填 https://域名:端口（自签 cert 第一次会弹\"信任\"）\n• 内网机器用 reverse-agent 推给 relay，不需要在这加")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(3)
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        // 背景渐变统一由 RootView 铺一层
        .scrollContentBackground(.hidden)
        .navigationTitle(isEdit ? "编辑服务器" : "添加服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { onClose() }
                    .foregroundStyle(Theme.primary)
                    .disabled(busy)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEdit ? "保存" : "添加") { doSave() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .disabled(busy)
            }
        }
        // editing 变化（进入编辑 / 保存后回 nil）时同步表单字段
        .task(id: editing?.id) { syncFields() }
        .alert("信任此证书？", isPresented: $showTrustDialog) {
            Button("取消", role: .cancel) {
                testResult = "❌ 证书未被信任"
                testOk = false
            }
            Button("信任") { acceptTrustAndRetest() }
        } message: {
            Text("此服务器使用自签或不可信证书。\n请与服务器管理员确认以下指纹一致后再信任：\n\n\(pendingFingerprint ?? "")\n\n指纹一致？点\"信任\"后保存到本机。")
        }
    }

    // MARK: - 表单卡片

    private var formCard: some View {
        VStack(spacing: 0) {
            fieldRow(label: "显示名称") {
                TextField("例如：家里 NAS / 美国 VPS", text: $name)
            }
            divider
            fieldRow(label: "域名或 IP") {
                TextField("agent.example.com 或 192.0.2.1", text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            divider
            HStack(spacing: 12) {
                fieldRow(label: "端口") {
                    TextField("例如 9009", text: $port)
                        .keyboardType(.numberPad)
                }
                Picker("", selection: $useHttps) {
                    Text("HTTPS").tag(true)
                    Text("HTTP").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 140)
            }
            .padding(.vertical, 4)
            divider
            fieldRow(label: "Agent Token") {
                HStack(spacing: 8) {
                    Group {
                        if obscureToken {
                            SecureField("agent 启动时配置的密钥", text: $token)
                        } else {
                            TextField("agent 启动时配置的密钥", text: $token)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button {
                        obscureToken.toggle()
                    } label: {
                        Image(systemName: obscureToken ? "eye" : "eye.slash")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .cardSurface(cornerRadius: 16)
    }

    private func fieldRow<Content: View>(label: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 84, alignment: .leading)
            content()
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.trackBackground)
            .frame(height: 1)
    }

    // MARK: - URL 预览 + 测试结果

    private var urlPreview: some View {
        Text("实际地址：\(fullUrl)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .cardSurface(cornerRadius: 10, stroke: Theme.primaryLight.opacity(0.3))
    }

    private func testResultBox(_ r: String) -> some View {
        Text(r)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(testOk ? Theme.success : Theme.textPrimary)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background((testOk ? Theme.success : Theme.danger).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke((testOk ? Theme.success : Theme.danger).opacity(0.4), lineWidth: 0.5)
            )
    }

    // MARK: - 字段同步

    private func syncFields() {
        testResult = nil
        testOk = false
        busy = false
        pendingFingerprint = nil
        if let s = editing {
            name = s.name
            host = s.host
            port = s.port > 0 ? "\(s.port)" : ""
            useHttps = s.https
            token = store.tokenFor(s.id) ?? ""
            obscureToken = true
        } else {
            name = ""
            host = ""
            port = ""
            useHttps = true
            token = ""
            obscureToken = true
        }
    }

    /// 编辑时 token 留空 → 用旧 token（对齐 Dart）
    private func resolvedToken() -> String {
        let t = token.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        if let s = editing { return store.tokenFor(s.id) ?? "" }
        return ""
    }

    // MARK: - 测试连接

    private func doTest() {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty {
            testResult = "❌ 请先填域名或 IP"; testOk = false; return
        }
        guard let portNum = Int(port.trimmingCharacters(in: .whitespaces)) else {
            testResult = "❌ 端口必须是数字"; testOk = false; return
        }
        let tok = resolvedToken()
        if tok.isEmpty {
            testResult = "❌ 请先填 Agent Token"; testOk = false; return
        }
        busy = true
        testResult = nil
        testOk = false
        let url = "\(scheme)://\(h):\(portNum)"
        pendingUrl = url
        pendingToken = tok
        Task {
            let res = await store.testAgent(url: url, token: tok)
            // TLS 不可信且捕获到指纹 → 弹信任确认框
            if let fp = res.untrustedFingerprint {
                pendingFingerprint = fp
                showTrustDialog = true
                busy = false
                return
            }
            testOk = res.success
            testResult = res.success ? "✅ 连接成功" : "❌ \(res.error ?? "未知错误")"
            busy = false
        }
    }

    private func acceptTrustAndRetest() {
        guard let fp = pendingFingerprint else { return }
        TrustStore.trust(origin: pendingUrl, fingerprint: fp)
        store.refreshTrustedCertCount()
        busy = true
        Task {
            let res = await store.testAgent(url: pendingUrl, token: pendingToken)
            testOk = res.success
            testResult = res.success
                ? "✅ 证书已信任，连接成功"
                : "❌ \(res.error ?? "仍无法连接")"
            busy = false
        }
    }

    // MARK: - 保存

    private func doSave() {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty {
            testResult = "❌ 请填域名或 IP"; return
        }
        guard let portNum = Int(port.trimmingCharacters(in: .whitespaces)) else {
            testResult = "❌ 端口必须是数字"; return
        }
        let tok = resolvedToken()
        if tok.isEmpty {
            testResult = "❌ 请填 Agent Token"; return
        }
        busy = true
        let url = "\(scheme)://\(h):\(portNum)"
        let nm = name.trimmingCharacters(in: .whitespaces)
        let finalName = nm.isEmpty ? h : nm
        if let s = editing {
            store.updateServer(id: s.id, name: finalName, url: url, token: tok)
        } else {
            _ = store.addAgentServer(name: finalName, url: url, token: tok)
        }
        busy = false
        onClose()
    }
}
