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

class IOSApp extends StatefulWidget {
  final MonitorStore store;
  const IOSApp({super.key, required this.store});

  @override
  State<IOSApp> createState() => _IOSAppState();
}

class _IOSAppState extends State<IOSApp> {
  // 修：添加 tab 跟机器/设置一样是 tab 切换，不再是 action button / push modal。
  // _currentIndex 0=机器 / 1=设置 / 2=添加 —— IndexedStack 瞬间切换，0 动画。
  int _currentIndex = 0;
  // 修：编辑模式——长按 → 菜单 → 编辑，会切到 IndexedStack[2] + 设 initial
  MonitorServer? _editingServer;
  bool _firstLaunchChecked = false;

  // 每个 tab 的 Navigator state key（添加 tab 走 IndexedStack 不需要 navigator，
  // 但 machines / settings 需要）
  // 修 Bug 1：之前只有 _machinesNavigatorKey，导致设置 tab 时点不动添加
  // —— push 走错 navigator 了
  final _machinesNavigatorKey = GlobalKey<NavigatorState>();
  final _settingsNavigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // 不再监听 store —— 5s 轮询会触发 setState rebuild 整个 IndexedStack，
    // 切 tab 时如果刚好赶上一次 poll = 视觉卡顿。
    // store 变化由各 tab 自己监听。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkFirstLaunch();
    });
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
      // 修：现在添加 tab 走 IndexedStack[2]，直接 setState 切过去
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _currentIndex = 2);
      });
    }
  }

  // 修 Bug 1：返回当前 tab 的 Navigator
  // （添加 tab 走 IndexedStack 不需要 navigator）
  NavigatorState? _activeNavigator() {
    switch (_currentIndex) {
      case 0:
        return _machinesNavigatorKey.currentState;
      case 1:
        return _settingsNavigatorKey.currentState;
      default:
        return _machinesNavigatorKey.currentState;
    }
  }

  // 共享的路由表（详情页/错误页）—— 修：add page 不再走 push 路由，
  // 走 IndexedStack[2] 直接显示（跟机器/设置 tab 一样瞬间切换）
  Route<dynamic>? _onGenerateRoute(RouteSettings settings) {
    Widget page;
    if (settings.name == '/detail') {
      page = IOSDetailPage(store: widget.store, server: settings.arguments as MonitorServer);
    } else if (settings.name == '/add') {
      // 修：detail page 点编辑会 push /add —— 水平滑入（不是 fullscreenDialog 从下滑入），
      // 关闭时 onClose 是 null，自动走 Navigator.pop
      // （IndexedStack[2] 模式下 IOSApp 直接放 IOSAddServerPage 不走这个路由）
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
      // 最右边 tab：添加（v2.4.31+）—— 选中时直接 push 添加服务器页
      IOSTabBarItem(
        icon: CupertinoIcons.add,
        activeIcon: CupertinoIcons.add_circled_solid,
        label: '添加',
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
                // 0: 机器 tab
                CupertinoTabView(
                  navigatorKey: _machinesNavigatorKey,
                  onGenerateRoute: _onGenerateRoute,
                  builder: (ctx) => IOSMachinesPage(
                    store: widget.store,
                    onEditServer: (s) {
                      // 修：编辑走 IndexedStack[2]（跟点添加 tab 一样瞬间切换）
                      setState(() {
                        _editingServer = s;
                        _currentIndex = 2;
                      });
                    },
                  ),
                ),
                // 1: 设置 tab
                CupertinoTabView(
                  navigatorKey: _settingsNavigatorKey,
                  onGenerateRoute: _onGenerateRoute,
                  builder: (ctx) => IOSSettingsPage(store: widget.store),
                ),
                // 2: 添加 tab —— 直接放 IOSAddServerPage，跟机器/设置一样瞬间切换
                // （之前 push modal 会有"从下往上"动画，跟其他 tab 体验不一致）
                IOSAddServerPage(
                  // key 用 _editingServer.id 区分，避免编辑 A → 编辑 B 时状态错乱
                  key: ValueKey(_editingServer?.id ?? '__new__'),
                  store: widget.store,
                  initial: _editingServer,
                  onClose: () {
                    setState(() {
                      _currentIndex = 0;
                      _editingServer = null;
                    });
                  },
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
              // 点当前 tab：
              //  - 机器/设置：弹回根（iOS 标准行为）
              //  - 添加：不做事（保持当前 form 状态，不弹回机器 tab）
              if (i == 0 || i == 1) {
                _activeNavigator()?.popUntil((r) => r.isFirst);
              }
              return;
            }
            if (i == 2) {
              // 切到添加 tab：清空 _editingServer（保证是"新建"模式）
              setState(() {
                _editingServer = null;
                _currentIndex = 2;
              });
              return;
            }
            setState(() => _currentIndex = i);
          },
          items: items,
        ),
      ],
    );
  }
}
