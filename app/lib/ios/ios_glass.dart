// iOS 27 Liquid Glass widgets —— 简化版
//
// 苹果官方文档核心原则：
// - "Reduce your use of custom backgrounds in controls and navigation
//   elements" —— 自定义 BackdropFilter blur 反而干扰系统原生 Liquid Glass
// - "Avoid overusing Liquid Glass effects" —— 只在最重要的元素上用
// - 标准控件 (bar / sheet / popover) 已经自动 Liquid Glass，不要再画
//
// 所以这里：
// - 不用 BackdropFilter
// - 卡片用白底 + 细边 + 轻投影（普通 iOS 风格）
// - StatusDot / StatTile 这些小元素保留（不涉及玻璃）
// - GlassContainer / GlassPill 改为简单的 Container（避免跟系统打架）

import 'package:flutter/cupertino.dart';
import 'ios_theme.dart';

/// 简化卡片：白底 + 细边 + 轻投影
/// 不再画 BackdropFilter blur（系统会处理 Liquid Glass）
class GlassContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final Color? borderColor;
  final double borderWidth;
  final BoxBorder? border;
  final double? width;
  final double? height;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = IOSTheme.radiusL,
    this.padding,
    this.margin,
    this.color,
    this.borderColor,
    this.borderWidth = 0.5,
    this.border,
    this.width,
    this.height,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? const Color(0xFFFFFFFF);
    final effectiveBorder = border ??
        Border.all(color: borderColor ?? const Color(0x1A000000), width: borderWidth);

    Widget body = Container(
      width: width,
      height: height,
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: effectiveColor,
        borderRadius: BorderRadius.circular(borderRadius),
        border: effectiveBorder,
        // 跟安卓一致的软投影
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000), // 黑色 8%
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );

    if (onTap != null || onLongPress != null) {
      body = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: body,
      );
    }

    return body;
  }
}

/// 玻璃药丸按钮：不再画 BackdropFilter，直接用 CupertinoButton
class GlassPill extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final Color? color;
  final EdgeInsetsGeometry padding;

  const GlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.color,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: padding,
      onPressed: onTap,
      borderRadius: BorderRadius.circular(100),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: color ?? IOSTheme.textPrimary, fontSize: 15),
        child: child,
      ),
    );
  }
}

/// iOS 27 风格背景：简单白+淡粉渐变（让系统处理任何玻璃效果）
/// 不要画光斑（iOS 标准 Liquid Glass 已经在系统控件上自动处理了）
class IOSBackground extends StatelessWidget {
  final Widget child;
  const IOSBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFFFFFFF),
            Color(0xFFFFF5F8),
            Color(0xFFFFFFFF),
          ],
          stops: [0.0, 0.5, 1.0],
        ),
      ),
      child: child,
    );
  }
}

/// 圆点状态指示器
class StatusDot extends StatelessWidget {
  final Color color;
  final double size;
  final bool pulse;
  const StatusDot({super.key, required this.color, this.size = 8.0, this.pulse = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.4),
            blurRadius: 4,
            spreadRadius: 0.5,
          ),
        ],
      ),
    );
  }
}

/// iOS 27 风格的 "mini stat" 数字 + 标签
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const StatTile({super.key, required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: IOSTheme.textTertiary,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? IOSTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }
}
