// iOS 27 风格主入口：浮动 tab bar + 内容切换

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../store.dart';
import 'ios_machines_page.dart';
import 'ios_detail_page.dart';
import 'ios_add_server_page.dart';
import 'ios_settings_page.dart';
import 'ios_glass.dart';
import 'ios_tab_bar.dart';

class IOSApp extends StatefulWidget {
  final MonitorStore store;
  const IOSApp({super.key, required this.store});

  @override
  State<IOSApp> createState() => _IOSAppState();
}

class _IOSAppState extends State<IOSApp> {
  int _currentIndex = 0;
  final _machinesNavKey = GlobalKey<NavigatorState>();
  final _settingsNavKey = GlobalKey<NavigatorState>();

  // 每个 tab 独立的 Navigator（标准 iOS 模式：tab 内 push 不会丢失其他 tab 的栈）
  Widget _buildTabNavigator(int index, GlobalKey<NavigatorState> navKey, Widget rootPage) {
    return Navigator(
      key: navKey,
      onGenerateRoute: (settings) {
        Widget page = rootPage;
        if (settings.name == '/detail') {
          page = IOSDetailPage(store: widget.store, server: settings.arguments as dynamic);
        } else if (settings.name == '/add') {
          page = IOSAddServerPage(store: widget.store);
        }
        return CupertinoPageRoute(builder: (_) => page, settings: settings);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <LiquidTabItem>[
      const LiquidTabItem(
        icon: CupertinoIcons.square_grid_2x2,
        activeIcon: CupertinoIcons.square_grid_2x2_fill,
        label: '机器',
      ),
      const LiquidTabItem(
        icon: CupertinoIcons.gear,
        activeIcon: CupertinoIcons.gear_solid,
        label: '设置',
      ),
    ];

    Widget body;
    switch (_currentIndex) {
      case 0:
        body = _buildTabNavigator(0, _machinesNavKey, IOSMachinesPage(store: widget.store));
        break;
      case 1:
        body = _buildTabNavigator(1, _settingsNavKey, IOSSettingsPage(store: widget.store));
        break;
      default:
        body = const SizedBox.shrink();
    }

    return Scaffold(
      // 不让 Scaffold 自动加背景（我们要用渐变 + 模糊）
      backgroundColor: Colors.transparent,
      body: IOSBackground(
        child: Stack(
          children: [
            Positioned.fill(child: body),
            LiquidTabBar(
              currentIndex: _currentIndex,
              onTap: (i) {
                if (i == _currentIndex) {
                  // 点当前 tab → 弹回根（iOS 标准行为）
                  if (i == 0) {
                    _machinesNavKey.currentState?.popUntil((r) => r.isFirst);
                  } else {
                    _settingsNavKey.currentState?.popUntil((r) => r.isFirst);
                  }
                } else {
                  setState(() => _currentIndex = i);
                }
              },
              items: tabs,
            ),
          ],
        ),
      ),
    );
  }
}
