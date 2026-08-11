// iOS 27 Liquid Glass 主入口：原生 CupertinoTabScaffold
//
// 苹果官方文档明确说：
// - "Leverage system frameworks to adopt Liquid Glass automatically"
//   标准组件 (bars, sheets, popovers, controls) 自动获得 Liquid Glass
// - "Reduce your use of custom backgrounds in controls and navigation
//   elements" —— 自己画 BackdropFilter blur 反而干扰系统原生 Liquid Glass
// - tab bar 应该是浮动的"小岛"形状，inset from edge
//
// 所以这里用 CupertinoTabScaffold（iOS 27 自动 Liquid Glass tab bar），
// 不要自己画。CupertinoTabView 自带 Navigator，通过 navigatorKey 控制。

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../store.dart';
import 'ios_add_server_page.dart';
import 'ios_detail_page.dart';
import 'ios_error_details_page.dart';
import 'ios_machines_page.dart';
import 'ios_settings_page.dart';

class IOSApp extends StatefulWidget {
  final MonitorStore store;
  const IOSApp({super.key, required this.store});

  @override
  State<IOSApp> createState() => _IOSAppState();
}

class _IOSAppState extends State<IOSApp> {
  // 首启只弹一次（SharedPreferences 持久化）
  bool _firstLaunchChecked = false;

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
      // 等下一帧 push（确保 navigator 已就绪）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _machinesNavigatorKey.currentState?.pushNamed('/add');
      });
    }
  }

  // 路由表（用 _machinesNavigatorKey 替代之前 buildTabNavigator 包装的方案）
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
    return CupertinoTabScaffold(
      tabBar: CupertinoTabBar(
        items: const [
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.square_grid_2x2),
            activeIcon: Icon(CupertinoIcons.square_grid_2x2_fill),
            label: '机器',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.gear),
            activeIcon: Icon(CupertinoIcons.gear_solid),
            label: '设置',
          ),
        ],
      ),
      tabBuilder: (context, index) {
        switch (index) {
          case 0:
            return CupertinoTabView(
              navigatorKey: _machinesNavigatorKey,
              onGenerateRoute: _onGenerateRoute,
              builder: (ctx) => IOSMachinesPage(store: widget.store),
            );
          case 1:
            return CupertinoTabView(
              onGenerateRoute: _onGenerateRoute,
              builder: (ctx) => IOSSettingsPage(store: widget.store),
            );
          default:
            return const SizedBox.shrink();
        }
      },
    );
  }
}
