// Design tokens —— 对齐 Flutter 版 lib/ios/ios_theme.dart（粉色 #FF6B95 + 白底）
// 以及 lib/ios/ios_helpers.dart 的状态/用量/温度判定逻辑。
// 深色模式：苹果原生风——背景纯黑→深灰渐变，卡片 #1C1C1E 实心深灰，
// 所有 token 随系统外观自动切换（UIColor dynamic provider）。

import SwiftUI

enum Theme {
    /// 构造随系统外观切换的动态颜色
    private static func dynamic(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    // 主色：粉色（跟安卓 Color(0xFFFF6B95) 完全一致；深色下提亮一档保证可读性）
    static let primary = dynamic(
        light: Color(red: 1.0, green: 0x6B / 255.0, blue: 0x95 / 255.0),
        dark: Color(red: 1.0, green: 0x7F / 255.0, blue: 0xA6 / 255.0))
    static let primaryDark = dynamic(
        light: Color(red: 0xE5 / 255.0, green: 0x50 / 255.0, blue: 0x7A / 255.0),
        dark: Color(red: 1.0, green: 0x6B / 255.0, blue: 0x95 / 255.0))
    static let primaryLight = dynamic(
        light: Color(red: 1.0, green: 0xB6 / 255.0, blue: 0xC1 / 255.0),
        dark: Color(red: 0x8E / 255.0, green: 0x5C / 255.0, blue: 0x6E / 255.0))

    // 语义色（跟安卓一致；这两个色在深色底上对比度足够，不切换）
    static let success = Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0)
    static let warning = Color(red: 0xF5 / 255.0, green: 0x9E / 255.0, blue: 0x0B / 255.0)
    static let danger = Color(red: 0xE5 / 255.0, green: 0x39 / 255.0, blue: 0x35 / 255.0)
    static let info = Color(red: 0x4F / 255.0, green: 0x8E / 255.0, blue: 0xF7 / 255.0)

    // 背景渐变：浅色白+浅粉；深色纯黑→#1A1A1E（苹果原生深色底）
    static let backgroundGradient = LinearGradient(
        colors: [
            dynamic(light: .white, dark: .black),
            dynamic(light: Color(red: 1.0, green: 0xE4 / 255.0, blue: 0xEC / 255.0),
                    dark: Color(red: 0x10 / 255.0, green: 0x10 / 255.0, blue: 0x12 / 255.0)),
            dynamic(light: Color(red: 1.0, green: 0xF0 / 255.0, blue: 0xF5 / 255.0),
                    dark: Color(red: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x1E / 255.0)),
            dynamic(light: .white, dark: .black),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // 进度条轨道 / chip 背景（深色下用系统填充色阶）
    static let trackBackground = dynamic(
        light: Color(red: 1.0, green: 0xF4 / 255.0, blue: 0xF7 / 255.0),
        dark: Color(red: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2E / 255.0))
    static let cardChipBackground = dynamic(
        light: Color(red: 1.0, green: 0xEE / 255.0, blue: 0xF2 / 255.0),
        dark: Color(red: 0x3A / 255.0, green: 0x3A / 255.0, blue: 0x3C / 255.0))

    // 文字（深色下对齐系统 label 色阶）
    static let textPrimary = dynamic(
        light: Color(red: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x1A / 255.0),
        dark: Color(red: 0xF2 / 255.0, green: 0xF2 / 255.0, blue: 0xF7 / 255.0))
    static let textSecondary = dynamic(
        light: Color(red: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2C / 255.0),
        dark: Color(red: 0xC7 / 255.0, green: 0xC7 / 255.0, blue: 0xCC / 255.0))
    static let textTertiary = dynamic(
        light: Color(red: 0x7A / 255.0, green: 0x7A / 255.0, blue: 0x82 / 255.0),
        dark: Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))

    // 卡片背景：浅色纯白实心；深色 #1C1C1E 实心（secondarySystemGroupedBackground 同值）
    static let cardBackground = dynamic(
        light: Color(red: 1.0, green: 1.0, blue: 1.0),
        dark: Color(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0))

    // 卡片描边：浅色淡粉；深色白色微亮边（深底上粉描边会脏）
    static let cardStroke = dynamic(
        light: Color(red: 1.0, green: 0xB6 / 255.0, blue: 0xC1 / 255.0).opacity(0.35),
        dark: Color.white.opacity(0.10))

    // 卡片阴影（深色底上加深才有层次）
    static let cardShadow = dynamic(
        light: Color.black.opacity(0.12),
        dark: Color.black.opacity(0.5))
}

// MARK: - 卡片表面（实心底 + 描边 + 阴影，浅深自动适配）

extension View {
    /// 统一卡片外观：实心底 + 柔和阴影 + 细描边（浅色淡粉 / 深色微白）
    func cardSurface(cornerRadius: CGFloat, stroke: Color = Theme.cardStroke) -> some View {
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
