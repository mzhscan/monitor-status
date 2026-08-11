// iOS 27 风格主入口：浮动 tab bar + 内容切换
//
// 跟安卓 main.dart 对齐：
//   - 首启自动弹添加服务器对话框（v2.4.3+ 行为）
//   - 错误详情页路由 /error-details
//
// 视觉保持 iOS 27 Liquid Glass（LiquidTabBar + GlassContainer）。

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors, Scaffold;
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../store.dart';
import 'ios_add_server_page.dart';
import 'ios_detail_page.dart';
import 'ios_error_details_page.dart';
import 'ios_machines_page.dart';
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

  // 首启只弹一次（SharedPreferences 持久化）
  bool _firstLaunchChecked = false;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkFirstLaunch();
    });
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChange);
    super.dispose();
  }

  void _onStoreChange() {
    if (mounted) setState(() {});
  }

  // v2.4.3 对齐安卓行为：首启（且没有 server 时）自动弹添加服务器对话框。
  Future<void> _checkFirstLaunch() async {
    if (_firstLaunchChecked) return;
    final store = widget.store;
    while (!store.firstLoadDone) {
      await Future.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
    }
    _firstLaunchChecked = true;
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool('first_launch_shown') ?? false;
    if (!shown && mounted && store.orderedServers.isEmpty) {
      await prefs.setBool('first_launch_shown', true);
      if (!mounted) return;
      // 切到 machines tab 然后 push add page
      setState(() => _currentIndex = 0);
      // 等待下一帧再 push，确保 navigator 已就绪
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      _machinesNavKey.currentState?.pushNamed('/add');
    }
  }

  // 每个 tab 独立的 Navigator（标准 iOS 模式：tab 内 push 不会丢失其他 tab 的栈）
  Widget _buildTabNavigator(int index, GlobalKey<NavigatorState> navKey, Widget rootPage) {
    return Navigator(
      key: navKey,
      onGenerateRoute: (settings) {
        Widget page = rootPage;
        if (settings.name == '/detail') {
          page = IOSDetailPage(store: widget.store, server: settings.arguments as MonitorServer);
        } else if (settings.name == '/add') {
          // arguments 可能是 MonitorServer（编辑）或 null（新增）
          final initial = settings.arguments as MonitorServer?;
          page = IOSAddServerPage(store: widget.store, initial: initial);
        } else if (settings.name == '/error-details') {
          page = IOSErrorDetailsPage(store: widget.store);
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
