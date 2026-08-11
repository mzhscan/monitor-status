// iOS 27 风格 design tokens —— 粉色 + 白色主题
//
// 跟安卓 app 配色一致：白底 + 浅粉渐变 + 粉色 #FF6B95 强调
// （保留 iOS 27 Liquid Glass 的玻璃质感：半透明 + 模糊 + 圆角）

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// iOS 27 Liquid Glass：颜色 + 圆角 + spring 曲线
class IOSTheme {
  // 主色：粉色（跟安卓 Color(0xFFFF6B95) 完全一致）
  static const Color primary = Color(0xFFFF6B95);
  static const Color primaryDark = Color(0xFFE5507A);  // hover/press
  static const Color primaryLight = Color(0xFFFFB6C1); // 浅粉（强调渐变）

  // 语义色（跟安卓一致）
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFE53935);
  static const Color info = Color(0xFF4F8EF7);

  // 背景渐变（白 + 浅粉，跟安卓 _GradientBackdrop 一致）
  static const List<Color> backgroundGradient = [
    Color(0xFFFFFFFF),
    Color(0xFFFFE4EC),
    Color(0xFFFFF0F5),
    Color(0xFFFFFFFF),
  ];

  // 玻璃表面：半透明白 + 高斯模糊
  // 跟安卓 GlassCard 'frosted' 模式一致的 50% 白 + 粉色边
  static const Color glassLight = Color(0x80FFFFFF); // 50% 白
  static const Color glassDark = Color(0xCCFFFFFF);  // 80% 白（更实）
  static const Color glassBorder = Color(0x55FFB6C1); // 浅粉边

  // 进度条 / 用量条 用的浅色轨道（跟安卓 Color(0x22FFB6C1) 风格一致）
  // 实色但淡淡的：之前 0xFFFFB0C5 太浓 → 0xFFFFD9E1 浅色但能看清
  static const Color trackBackground = Color(0xFFFFD9E1);

  // 文字（深色，跟安卓一致）
  static const Color textPrimary = Color(0xFF1A1A1A);
  static const Color textSecondary = Color(0xFF2C2C2C);
  static const Color textTertiary = Color(0xFF7A7A82);
  static const Color textHint = Color(0xFF9CA3AF);

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

  // 模糊半径
  static const double blurS = 10.0;
  static const double blurM = 25.0;
  static const double blurL = 40.0;

  // spring 曲线
  static const Curve springBounce = Curves.elasticOut;
  static const Curve springSmooth = Cubic(0.25, 0.1, 0.25, 1.0);
  static const Duration springDuration = Duration(milliseconds: 450);

  // 字体
  static const String fontFamily = '.SF Pro Text';
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

/// 在线状态颜色（基于 lastReceivedMs + maxStaleMs）
Color onlineStatusColor(bool online, int lastReceivedMs, {int maxStaleMs = 120000}) {
  if (lastReceivedMs == 0) return IOSTheme.textTertiary;
  if (online) return IOSTheme.success;
  final now = DateTime.now().millisecondsSinceEpoch;
  final age = now - lastReceivedMs;
  if (age < 300 * 1000) return IOSTheme.warning;
  return IOSTheme.danger;
}
