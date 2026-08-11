// iOS 27 液态玻璃 widgets —— 浅色（白+粉）主题
//
// 关键：BackdropFilter + ImageFilter.blur 做出毛玻璃
// 容器用半透明白 + 圆角 + 浅粉边
// 背景：白 + 浅粉渐变 + 粉/紫光斑（保留 iOS 27 视觉感）

import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'ios_theme.dart';

/// 液态玻璃容器（圆角矩形 + 高斯模糊背景）
class GlassContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double blur;
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
    this.blur = IOSTheme.blurM,
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
    final effectiveColor = color ?? IOSTheme.glassLight;
    final effectiveBorder = border ??
        Border.all(color: borderColor ?? IOSTheme.glassBorder, width: borderWidth);

    Widget body = Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        color: effectiveColor,
        borderRadius: BorderRadius.circular(borderRadius),
        border: effectiveBorder,
        boxShadow: const [
          // 软投影（粉色光晕）
          BoxShadow(
            color: Color(0x1AFF6B95), // 粉色 10%
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
          // 轻投影
          BoxShadow(
            color: Color(0x0F000000), // 黑色 6%
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            child: child,
          ),
        ),
      ),
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

/// 玻璃药丸按钮（iOS 27 风格：胶囊 + 毛玻璃）
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(100),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: CupertinoButton(
          padding: padding,
          onPressed: onTap,
          borderRadius: BorderRadius.circular(100),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 15),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// iOS 27 风格背景：白 + 浅粉渐变 + 粉色光斑
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
          colors: IOSTheme.backgroundGradient,
          stops: [0.0, 0.35, 0.7, 1.0],
        ),
      ),
      child: Stack(
        children: [
          // 几个静态模糊光斑（液态玻璃的"光"感，浅色版本）
          Positioned(
            top: -100,
            right: -50,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    IOSTheme.primary.withOpacity(0.10),
                    IOSTheme.primary.withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 200,
            left: -100,
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    IOSTheme.primaryLight.withOpacity(0.20),
                    IOSTheme.primaryLight.withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 100,
            right: -80,
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF7C5CFF).withOpacity(0.08),
                    const Color(0xFF7C5CFF).withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
          // 主内容
          child,
        ],
      ),
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
            color: color.withOpacity(0.5),
            blurRadius: 6,
            spreadRadius: 1,
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
