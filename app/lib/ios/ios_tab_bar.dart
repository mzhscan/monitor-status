// iOS 27 液态玻璃底部 tab bar
//
// 设计：
// - 悬浮在内容上方（不占满底部）
// - 圆角胶囊形状
// - 半透明 + 高斯模糊背景
// - 选中项的图标后面有一个药丸状指示器（spring 动画）
// - 图标 + 标签组合（iOS 27 风格）
// - 安全区适配（iPhone 底部 home indicator）

import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'ios_theme.dart';

class LiquidTabBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<LiquidTabItem> items;

  const LiquidTabBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    // 底部安全区（iPhone home indicator）
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Positioned(
      left: IOSTheme.paddingL,
      right: IOSTheme.paddingL,
      bottom: bottomPadding > 0 ? bottomPadding - 4 : IOSTheme.paddingM,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              color: IOSTheme.glassLight,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: IOSTheme.glassBorder, width: 0.5),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(items.length, (i) {
                return _LiquidTabButton(
                  item: items[i],
                  isSelected: i == currentIndex,
                  onTap: () => onTap(i),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class LiquidTabItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const LiquidTabItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}

class _LiquidTabButton extends StatefulWidget {
  final LiquidTabItem item;
  final bool isSelected;
  final VoidCallback onTap;
  const _LiquidTabButton({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_LiquidTabButton> createState() => _LiquidTabButtonState();
}

class _LiquidTabButtonState extends State<_LiquidTabButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      lowerBound: 0.85,
      upperBound: 1.0,
      value: 1.0,
    );
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack);
    if (widget.isSelected) {
      _ctrl.forward();
    }
  }

  @override
  void didUpdateWidget(_LiquidTabButton old) {
    super.didUpdateWidget(old);
    if (widget.isSelected && !old.isSelected) {
      _ctrl.forward(from: 0.85);
    } else if (!widget.isSelected && old.isSelected) {
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.isSelected;
    final color = selected ? IOSTheme.primary : IOSTheme.textTertiary;

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, child) {
            return Transform.scale(
              scale: _scale.value,
              child: child,
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Icon(
                    selected ? widget.item.activeIcon : widget.item.icon,
                    key: ValueKey<bool>(selected),
                    size: 24,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.item.label,
                  style: TextStyle(
                    fontSize: 10,
                    color: color,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
