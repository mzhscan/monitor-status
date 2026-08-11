// iOS 27+ "Liquid Glass" design tokens
//
// 知识截止 2026-01，Apple WWDC 26 (2026-06) 公布的具体规范我可能不完全准。
// 我按 Apple 一贯的设计语言做：半透明模糊、圆角、spring 动画、底部悬浮 tab bar。
// 用户看到后可以反馈哪里需要调。

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// iOS 27 液态玻璃：颜色 + 圆角 + spring 曲线
class IOSTheme {
  // 主色：系统蓝（iOS 27 应该也保持这个色系）
  static const Color primary = Color(0xFF007AFF);

  // 语义色
  static const Color success = Color(0xFF34C759);
  static const Color warning = Color(0xFFFF9500);
  static const Color danger = Color(0xFFFF3B30);
  static const Color info = Color(0xFF5AC8FA);

  // 背景：液态玻璃效果下，内容背景应该是渐变 + 模糊
  // 这里用 iOS 27 风格的彩色背景渐变（系统动态色可能进一步调）
  static const List<Color> backgroundGradient = [
    Color(0xFF0A0E1A),
    Color(0xFF1A1530),
    Color(0xFF0F0A1E),
  ];

  // 玻璃表面：半透明白/黑 + 高斯模糊
  static const Color glassLight = Color(0x33FFFFFF); // 20% 白
  static const Color glassDark = Color(0x1FFFFFFF);  // 12% 白
  static const Color glassBorder = Color(0x33FFFFFF); // 20% 白色边

  // 文字
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xCCFFFFFF);
  static const Color textTertiary = Color(0x80FFFFFF);

  // 圆角
  static const double radiusS = 8.0;
  static const double radiusM = 14.0;
  static const double radiusL = 20.0;
  static const double radiusXL = 28.0;

  // 间距
  static const double paddingXS = 4.0;
  static const double paddingS = 8.0;
  static const double paddingM = 12.0;
  static const double paddingL = 16.0;
  static const double paddingXL = 24.0;

  // 模糊半径（iOS 27 玻璃效果）
  static const double blurS = 10.0;
  static const double blurM = 25.0;
  static const double blurL = 40.0;

  // spring 曲线（iOS 27 强调高弹性、bouncy 反馈）
  static const Curve springBounce = Curves.elasticOut;
  static const Curve springSmooth = Cubic(0.25, 0.1, 0.25, 1.0);
  static const Duration springDuration = Duration(milliseconds: 450);

  // 字体
  static const String fontFamily = '.SF Pro Text';  // iOS 自动 fallback
  static const String fontFamilyDisplay = '.SF Pro Display';
}

/// 状态颜色 helper
Color statusColor(String? status) {
  switch (status) {
    case 'active':
      return IOSTheme.success;
    case 'inactive':
    case 'failed':
      return IOSTheme.danger;
    default:
      return IOSTheme.textTertiary;
  }
}

/// 在线状态颜色（基于 lastSuccessMs + maxStaleMs）
Color onlineStatusColor(bool online, int lastReceivedMs, {int maxStaleMs = 120000}) {
  if (lastReceivedMs == 0) return IOSTheme.textTertiary;
  if (online) return IOSTheme.success;
  // lastReceivedMs > 0 但 online = false（stale 或 offline）
  final now = DateTime.now().millisecondsSinceEpoch;
  final age = now - lastReceivedMs;
  if (age < 300 * 1000) return IOSTheme.warning;  // 卡
  return IOSTheme.danger;  // 离线
}
