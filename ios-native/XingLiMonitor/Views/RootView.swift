// 根视图：3 tab 原生 TabView（对齐 Flutter 版 ios_app.dart 的
// IndexedStack：服务器 / 设置 / 添加）。iOS 27 上 TabView 自动 Liquid Glass。

import SwiftUI

enum AppTab: Hashable {
    case machines
    case add
    case settings
}

struct RootView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    /// 启动参数 hook（调试/截图用）：-startTabAdd / -startTabSettings
    @State private var selectedTab: AppTab = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-startTabAdd") { return .add }
        if args.contains("-startTabSettings") { return .settings }
        return .machines
    }()
    /// 非空 = 编辑模式（添加 tab 显示编辑表单）
    @State private var editingServer: MonitorServer?
    /// 编辑/保存后回到哪个 tab
    @State private var returnTab: AppTab = .machines
    /// 服务器 tab 导航栈（程序化：卡片点击不带 NavigationLink 箭头）
    @State private var machinesPath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("服务器", systemImage: "list.bullet.rectangle", value: .machines) {
                NavigationStack(path: $machinesPath) {
                    MachinesView(
                        onOpenServer: { machinesPath.append($0) },
                        onEditServer: { server in
                            returnTab = .machines
                            editingServer = server
                            selectedTab = .add
                        }
                    )
                }
            }
            Tab("添加", systemImage: "plus", value: .add) {
                NavigationStack {
                    AddEditServerView(
                        editing: editingServer,
                        onClose: {
                            let back = editingServer != nil ? returnTab : .machines
                            editingServer = nil
                            selectedTab = back
                        }
                    )
                }
            }
            Tab("设置", systemImage: "gearshape", value: .settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .onChange(of: scenePhase) { _, phase in
            // 退后台前约一次后台刷新，系统会隔一阵唤醒跑一轮（推表/补通知）
            if phase == .background { BackgroundRefresh.shared.scheduleNext() }
        }
    }
}
