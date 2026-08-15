// 星黎监控 watchOS 版入口（伴生模式：数据由 iPhone 端推送）。

import SwiftUI

@main
struct XingLiMonitorWatchApp: App {
    @State private var session = WatchSession()

    var body: some Scene {
        WindowGroup {
            WatchOverviewView()
                .environment(session)
                .task { session.start() }
        }
    }
}
