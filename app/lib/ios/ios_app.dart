// iOS 27 Liquid Glass 主入口：Stack + IndexedStack + 自造浮动小岛 tab bar
//
// Flutter 3.44.9 的 CupertinoTabBar 还是 iOS 18 全宽样式（不浮动），
// 所以这里用 IndexedStack + 自造 IOSTabBar 实现 iOS 27 的浮动小岛。
// 每个 tab 用 CupertinoTabView 拿系统 Navigator + iOS 27 Liquid Glass 容器。

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../store.dart';
import 'ios_add_server_page.dart';
import 'ios_detail_page.dart';
import 'ios_error_details_page.dart';
import 'ios_machines_page.dart';
import 'ios_settings_page.dart';
import 'ios_tab_bar.dart';
import 'ios_theme.dart';

class IOSApp extends StatefulWidget {
  final MonitorStore store;
  const IOSApp({super.key, required this.store});

  @override
  State<IOSApp> createState() => _IOSAppState();
}

class _IOSAppState extends State<IOSApp> {
  int _currentIndex = 0;
  bool _firstLaunchChecked = false;
  bool _pendingFirstLaunchAdd = false;

  // machines tab 的 Navigator state key —— first-launch 时通过它 push add page
  final _machinesNavigatorKey = GlobalKey<NavigatorState>();

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
      _pendingFirstLaunchAdd = true;
      // 等下一帧 push（确保 navigator 已就绪）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _machinesNavigatorKey.currentState?.pushNamed('/add');
        _pendingFirstLaunchAdd = false;
      });
    }
  }

  // 共享的路由表（详情页/添加页/错误页）
  Route<dynamic>? _onGenerateRoute(RouteSettings settings) {
    Widget page;
    if (settings.name == '/detail') {
      page = IOSDetailPage(store: widget.store, server: settings.arguments as MonitorServer);
    } else if (settings.name == '/add') {
      final initial = settings.arguments as MonitorServer?;
      page = IOSAddServerPage(store: widget.store, initial: initial);
    } else if (settings.name == '/error-details') {
      page = IOSErrorDetailsPage(store: widget.store);
    } else {
      return null;
    }
    return CupertinoPageRoute(builder: (_) => page, settings: settings);
  }

  @override
  Widget build(BuildContext context) {
    final items = const [
      IOSTabBarItem(
        icon: CupertinoIcons.square_grid_2x2,
        activeIcon: CupertinoIcons.square_grid_2x2_fill,
        label: '机器',
      ),
      IOSTabBarItem(
        icon: CupertinoIcons.gear,
        activeIcon: CupertinoIcons.gear_solid,
        label: '设置',
      ),
    ];

    return Stack(
      children: [
        // 内容：IndexedStack（保留每个 tab 的状态）+ 背景
        Positioned.fill(
          child: Container(
            // iOS 27 风格：简单白底，让系统 / 卡片自己处理任何细节
            color: const Color(0xFFFFFFFF),
            child: IndexedStack(
              index: _currentIndex,
              children: [
                // 机器 tab
                CupertinoTabView(
                  navigatorKey: _machinesNavigatorKey,
                  onGenerateRoute: _onGenerateRoute,
                  builder: (ctx) => IOSMachinesPage(store: widget.store),
                ),
                // 设置 tab
                CupertinoTabView(
                  onGenerateRoute: _onGenerateRoute,
                  builder: (ctx) => IOSSettingsPage(store: widget.store),
                ),
              ],
            ),
          ),
        ),
        // iOS 27 风格浮动小岛 tab bar
        IOSTabBar(
          currentIndex: _currentIndex,
          onTap: (i) {
            if (i == _currentIndex) {
              // 点当前 tab → 弹回根（iOS 标准行为）
              if (i == 0) {
                _machinesNavigatorKey.currentState?.popUntil((r) => r.isFirst);
              } else {
                // settings tab 没有保存 key，简化处理
              }
            } else {
              setState(() => _currentIndex = i);
            }
          },
          items: items,
        ),
      ],
    );
  }
}
