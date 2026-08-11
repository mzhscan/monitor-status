// iOS 27 风格浮动"小岛" tab bar
//
// Flutter 3.44.9 的 CupertinoTabBar 还没适配 iOS 27 的浮动小岛样式，
// 所以这里自己画一个。但要遵守苹果的原则：
// - 白底 + 细边 + 轻投影（不用 BackdropFilter，避免干扰系统 Liquid Glass）
// - 浮动在底部，inset from screen edge
// - 选中态用主色（粉），未选中用次要色（灰）
// - 用 spring 动画切换选中状态

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;
import 'ios_theme.dart';

class IOSTabBarItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const IOSTabBarItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}

class IOSTabBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<IOSTabBarItem> items;

  const IOSTabBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Positioned(
      bottom: bottomPadding > 0 ? bottomPadding + 4 : 8,
      left: IOSTheme.paddingXL,
      right: IOSTheme.paddingXL,
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: const Color(0x1A000000), width: 0.5),
          // 修：减弱 boxShadow —— 之前黑色 10% blur 24 + 粉色 8% blur 32 都向下投影，
          // 阴影延伸到 tab bar 下方 30+px 形成"灰色层"遮挡卡片内容。
          // 改成：极浅向上阴影（iOS 27 浮动小岛标准，几乎不投影到下方）
          boxShadow: const [
            BoxShadow(
              color: Color(0x0F000000), // 6% 黑色
              blurRadius: 16,
              offset: Offset(0, -1),  // 向上 1px（让 tab bar 顶部有立体感）
            ),
            BoxShadow(
              color: Color(0x0AFF6B95), // 4% 粉
              blurRadius: 12,
              offset: Offset(0, 2),  // 向下 2px（极轻）
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(items.length, (i) {
            return _IOSTabBarButton(
              item: items[i],
              isSelected: i == currentIndex,
              onTap: () => onTap(i),
            );
          }),
        ),
      ),
    );
  }
}

class _IOSTabBarButton extends StatefulWidget {
  final IOSTabBarItem item;
  final bool isSelected;
  final VoidCallback onTap;
  const _IOSTabBarButton({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_IOSTabBarButton> createState() => _IOSTabBarButtonState();
}

class _IOSTabBarButtonState extends State<_IOSTabBarButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.isSelected;
    final color = selected ? IOSTheme.primary : IOSTheme.textTertiary;

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            // 选中态：粉底圆角（iOS 27 风格）
            color: selected
                ? IOSTheme.primary.withOpacity(_pressed ? 0.20 : 0.12)
                : (_pressed ? const Color(0x0A000000) : Colors.transparent),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) => ScaleTransition(
                    scale: Tween<double>(begin: 0.7, end: 1.0).animate(
                      CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
                    ),
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                  child: Icon(
                    selected ? widget.item.activeIcon : widget.item.icon,
                    key: ValueKey<bool>(selected),
                    size: 22,
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
