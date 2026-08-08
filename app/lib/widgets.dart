// Common widgets shared across pages — glass-styled to match the theme
// (white + sakura pink palette).
//
// Style flags (set at build time by --dart-define):
//   GLASS_STYLE = "frosted"  (default — true backdrop blur, semi-transparent)
//   GLASS_STYLE = "solid"    (opaque white card with white border + shadow)

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'models.dart';

/// Build-time selected glass style.
const String kGlassStyle = String.fromEnvironment('GLASS_STYLE', defaultValue: 'frosted');
bool get _isSolid => kGlassStyle == 'solid';

/// Color for usage percentages.
Color usageColor(double pct) {
  if (pct >= 85) return const Color(0xFFE53935);
  if (pct >= 60) return const Color(0xFFF59E0B);
  return const Color(0xFF10B981);
}

Color tempColor(double t) {
  if (t >= 80) return const Color(0xFFE53935);
  if (t >= 65) return const Color(0xFFF59E0B);
  if (t > 0) return const Color(0xFF10B981);
  return const Color(0xFF9CA3AF);
}

/// Frosted glass surface.
///   - "frosted" style: translucent white + real backdrop blur (lets the
///     gradient bleed through, softens what's behind).
///   - "solid" style: opaque white + 1px white border + soft shadow.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.radius = 18,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    if (_isSolid) {
      return _buildSolid(child, padding, radius, onTap, onLongPress);
    }
    return _buildFrosted(child, padding, radius, onTap, onLongPress);
  }

  Widget _buildSolid(Widget child, EdgeInsetsGeometry padding, double radius, VoidCallback? onTap, VoidCallback? onLongPress) {
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF), // opaque white
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: const Color(0xFFFFFFFF), width: 1.0),
        boxShadow: const [
          // soft black drop shadow for definition
          BoxShadow(color: Color(0x18000000), blurRadius: 14, offset: Offset(0, 4)),
          // subtle pink glow to stay on-theme
          BoxShadow(color: Color(0x1AFFC4D5), blurRadius: 24, offset: Offset(0, 8)),
        ],
      ),
      child: child,
    );
    if (onTap == null && onLongPress == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(radius),
        child: card,
      ),
    );
  }

  Widget _buildFrosted(Widget child, EdgeInsetsGeometry padding, double radius, VoidCallback? onTap, VoidCallback? onLongPress) {
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: const Color(0x80FFFFFF), // white 50% alpha
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: const Color(0x40FFB6C1), width: 0.6),
            boxShadow: const [
              BoxShadow(color: Color(0x14FF6B95), blurRadius: 20, offset: Offset(0, 6)),
            ],
          ),
          child: child,
        ),
      ),
    );
    if (onTap == null && onLongPress == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(radius),
        child: card,
      ),
    );
  }
}

class UsageBar extends StatelessWidget {
  final String label;
  final String valueText;
  final double percent;
  final IconData icon;
  final Color? colorOverride;
  final bool showLabel;
  const UsageBar({
    super.key,
    required this.label,
    required this.valueText,
    required this.percent,
    required this.icon,
    this.colorOverride,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = colorOverride ?? usageColor(percent);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showLabel)
            Row(
              children: [
                Icon(icon, size: 18, color: c),
                const SizedBox(width: 8),
                Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF2C2C2C))),
                const Spacer(),
                Text(valueText, style: TextStyle(fontSize: 14, color: c, fontWeight: FontWeight.w600)),
              ],
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 6,
              value: (percent.clamp(0, 100)) / 100,
              backgroundColor: const Color(0x22FFB6C1),
              valueColor: AlwaysStoppedAnimation<Color>(c),
            ),
          ),
        ],
      ),
    );
  }
}

class StatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color? color;
  const StatTile({super.key, required this.icon, required this.value, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? const Color(0xFFFF6B95);
    return GlassCard(
      padding: const EdgeInsets.all(10),
      radius: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: c),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF7A7A82)), overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c)),
        ],
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  final AgentData agent;
  const StatusBadge({super.key, required this.agent});

  @override
  Widget build(BuildContext context) {
    final Color c;
    final String text;
    if (agent.isOnline) {
      c = const Color(0xFF10B981);
      text = '在线';
    } else if (agent.isStale) {
      c = const Color(0xFFF59E0B);
      text = '滞后 ${agent.secondsAgo}s';
    } else {
      c = const Color(0xFFE53935);
      text = agent.secondsAgo > 0 ? '离线 ${agent.secondsAgo}s' : '无数据';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle, boxShadow: [BoxShadow(color: c.withOpacity(0.6), blurRadius: 4)])),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes <= 0) return '0 B';
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var i = 0;
  double v = bytes.toDouble();
  while (v >= 1024 && i < sizes.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : decimals)} ${sizes[i]}';
}

String formatDuration(int seconds) {
  if (seconds < 60) return '$seconds秒前';
  if (seconds < 3600) return '${(seconds / 60).floor()}分钟前';
  if (seconds < 86400) return '${(seconds / 3600).floor()}小时前';
  return '${(seconds / 86400).floor()}天前';
}

/// Translate systemd status strings to Chinese.
String translateStatus(String s) {
  switch (s) {
    case 'active':
      return '运行中';
    case 'inactive':
      return '未运行';
    case 'failed':
      return '已失败';
    case 'activating':
      return '启动中';
    case 'deactivating':
      return '停止中';
    case 'reloading':
      return '重载中';
    case 'maintenance':
      return '维护中';
    default:
      return s.isEmpty ? '未知' : s;
  }
}
