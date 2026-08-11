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
  int _currentIndex = 0;
  // 修 Bug A：点"添加"tab 之前所在的 tab（机器=0 / 设置=1），
  // add page pop 时回到原 tab
  int _previousIndex = 0;
  bool _firstLaunchChecked = false;
  bool _pendingFirstLaunchAdd = false;

  // 每个 tab 的 Navigator state key（添加 tab 不需要，但 machines / settings 需要）
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
      // 等下一帧 push（确保 navigator 已就绪）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _activeNavigator()?.pushNamed('/add');
      });
    }
  }

  // 修 Bug 1：返回当前 tab 的 Navigator
  // （添加 tab 走的是当前 tab 的 navigator，保持 modal 在当前 tab 内）
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

  // 共享的路由表（详情页/添加页/错误页）
  Route<dynamic>? _onGenerateRoute(RouteSettings settings) {
    Widget page;
    // 修 Bug B：add page 用 fullscreenDialog 模式（iOS 27 标准添加行为）
    // —— 从下滑入 + 背景 dim + 顶部圆角，0.4s 转场不再跟底 tab 内容"重叠"。
    // 默认 CupertinoPageRoute 是水平滑入（modal sheet 风格），半透明期间看到底 tab。
    final isFullscreenDialog = settings.name == '/add';
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
    return CupertinoPageRoute(
      fullscreenDialog: isFullscreenDialog,
      builder: (_) => page,
      settings: settings,
    );
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
                  builder: (ctx) => IOSMachinesPage(store: widget.store),
                ),
                // 1: 设置 tab
                CupertinoTabView(
                  navigatorKey: _settingsNavigatorKey,
                  onGenerateRoute: _onGenerateRoute,
                  builder: (ctx) => IOSSettingsPage(store: widget.store),
                ),
                // 2: "添加" tab —— 占位：打开时直接 push add page
                // （实际 push 在 onTap 处理）
                const SizedBox.shrink(),
              ],
            ),
          ),
        ),
        // iOS 27 风格浮动小岛 tab bar
        IOSTabBar(
          currentIndex: _currentIndex,
          onTap: (i) async {
            if (i == 2) {
              // 最右边"添加"tab：点一下直接 push add page
              // 修 Bug 1：走当前 tab 的 Navigator（设置 tab 时也能正常 push）
              // 修 Bug A：保存原 tab index，先 setState 让"添加"tab 显示选中状态，
              // push 完（add page pop 后）回到原 tab
              _previousIndex = _currentIndex;
              setState(() => _currentIndex = 2);
              await _activeNavigator()?.pushNamed('/add');
              if (!mounted) return;
              setState(() => _currentIndex = _previousIndex);
              return;
            }
            if (i == _currentIndex) {
              // 点当前 tab → 弹回根（iOS 标准行为）
              _activeNavigator()?.popUntil((r) => r.isFirst);
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
