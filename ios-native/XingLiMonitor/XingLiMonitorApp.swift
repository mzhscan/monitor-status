// Swift 原生版入口（v3.0.0+）。跟 Flutter 版并存：Bundle ID 复用
// com.mzhhua.monitorstatus，启动时读 Flutter 版写入的 NSUserDefaults /
// Keychain 数据，实现无缝迁移。

import SwiftUI

@main
struct XingLiMonitorApp: App {
    @State private var store = MonitorStore()

    init() {
        // iOS 27 Liquid Glass：系统组件（TabView/NavigationStack）自动玻璃化
        UserDefaults.standard.register(defaults: [:])
        // 后台刷新 handler 必须启动时注册（含系统为 BGTask 后台拉起的场景）
        BackgroundRefresh.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { await store.start() }
                .tint(Theme.primary)
        }
    }
}
