// Design tokens —— 对齐 Flutter 版 lib/ios/ios_theme.dart（粉色 #FF6B95 + 白底）
// 以及 lib/ios/ios_helpers.dart 的状态/用量/温度判定逻辑。

import SwiftUI

enum Theme {
    // 主色：粉色（跟安卓 Color(0xFFFF6B95) 完全一致）
    static let primary = Color(red: 1.0, green: 0x6B / 255.0, blue: 0x95 / 255.0)
    static let primaryDark = Color(red: 0xE5 / 255.0, green: 0x50 / 255.0, blue: 0x7A / 255.0)
    static let primaryLight = Color(red: 1.0, green: 0xB6 / 255.0, blue: 0xC1 / 255.0)

    // 语义色（跟安卓一致）
    static let success = Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0)
    static let warning = Color(red: 0xF5 / 255.0, green: 0x9E / 255.0, blue: 0x0B / 255.0)
    static let danger = Color(red: 0xE5 / 255.0, green: 0x39 / 255.0, blue: 0x35 / 255.0)
    static let info = Color(red: 0x4F / 255.0, green: 0x8E / 255.0, blue: 0xF7 / 255.0)

    // 背景渐变（白 + 浅粉）
    static let backgroundGradient = LinearGradient(
        colors: [
            Color.white,
            Color(red: 1.0, green: 0xE4 / 255.0, blue: 0xEC / 255.0),
            Color(red: 1.0, green: 0xF0 / 255.0, blue: 0xF5 / 255.0),
            Color.white,
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // 进度条轨道 / chip 背景
    static let trackBackground = Color(red: 1.0, green: 0xF4 / 255.0, blue: 0xF7 / 255.0)
    static let cardChipBackground = Color(red: 1.0, green: 0xEE / 255.0, blue: 0xF2 / 255.0)

    // 文字
    static let textPrimary = Color(red: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x1A / 255.0)
    static let textSecondary = Color(red: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2C / 255.0)
    static let textTertiary = Color(red: 0x7A / 255.0, green: 0x7A / 255.0, blue: 0x82 / 255.0)

    // 卡片背景：纯白 #FFFFFF，透明度 0%（完全不透明、实心）
    static let cardBackground = Color(red: 1.0, green: 1.0, blue: 1.0).opacity(1.0)

    // 卡片阴影（加深一档，白底上更明显）
    static let cardShadow = Color.black.opacity(0.12)
}

// MARK: - 卡片表面（纯白底 + 淡粉描边 + 阴影）

extension View {
    /// 统一白卡外观：纯白不透明底（#FFFFFF）+ 柔和阴影 + 淡粉细描边
    func cardSurface(cornerRadius: CGFloat, stroke: Color = Theme.primaryLight.opacity(0.35)) -> some View {
        self
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: Theme.cardShadow, radius: 14, x: 0, y: 5)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(stroke, lineWidth: 0.5)
            )
    }
}

// MARK: - 状态判定（对齐 ios_helpers.dart computeStatus）

struct ServerStatus {
    let label: String   // "加载中" / "在线" / "卡 Xs" / "离线"
    let color: Color
    let secondsAgo: Int // -1 = 还没成功过
}

/// 从 lastSuccess（app 端 poll 成功时间）算状态。跟安卓 StatusBadge 同语义。
func computeStatus(_ lastSuccess: Date?) -> ServerStatus {
    guard let lastSuccess else {
        return ServerStatus(label: "加载中", color: Theme.textTertiary, secondsAgo: -1)
    }
    let sa = Int(Date().timeIntervalSince(lastSuccess).rounded())
    if sa < 30 {
        return ServerStatus(label: "在线", color: Theme.success, secondsAgo: sa)
    } else if sa < 300 {
        return ServerStatus(label: "卡 \(sa)s", color: Theme.warning, secondsAgo: sa)
    } else {
        return ServerStatus(label: "离线", color: Theme.danger, secondsAgo: sa)
    }
}

/// 使用率颜色（跟安卓 usageColor 对齐）
func usageColor(_ pct: Double) -> Color {
    if pct >= 85 { return Theme.danger }
    if pct >= 60 { return Theme.warning }
    return Theme.success
}

/// 温度颜色（跟安卓 tempColor 对齐）
func tempColor(_ t: Double) -> Color {
    if t >= 80 { return Theme.danger }
    if t >= 65 { return Theme.warning }
    if t > 0 { return Theme.success }
    return Theme.textTertiary
}

/// HH:MM:SS 本地时间格式化
func fmtTime(_ t: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: t)
}

/// GB 格式化（对齐详情页 _XuiVpsSectionState.fmtGb：<1GB 显示 MB）
func fmtGb(_ gb: Double) -> String {
    if gb < 1 {
        return String(format: "%.0f MB", gb * 1024)
    }
    if gb < 100 {
        return String(format: "%.1f GB", gb)
    }
    return String(format: "%.0f GB", gb)
}
