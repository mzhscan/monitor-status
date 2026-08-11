// App entry: wires MonitorStore to the UI tree.
// v2.4.26+: iOS 平台自动用 iOS 27 液态玻璃风格（lib/ios/），
//            Android 平台还是原来的 Material 3 风格（lib/overview_page.dart 等）。
//            业务逻辑（API / store / models / errors）完全复用。

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'about_page.dart';
import 'add_server_dialog.dart';
import 'dynamic_server_page.dart';
import 'error_page.dart';
import 'ios/ios_app.dart';
import 'ios/ios_theme.dart' as ios_theme;
import 'overview_page.dart';
import 'store.dart';

void main() {
  runApp(const MonitorApp());
}

class MonitorApp extends StatefulWidget {
  const MonitorApp({super.key});

  @override
  State<MonitorApp> createState() => _MonitorAppState();
}

class _MonitorAppState extends State<MonitorApp> {
  // v2.4.26+: 检测平台 — iOS 用液态玻璃 UI，Android 用 Material 3
  bool get _isIOS {
    if (kIsWeb) return false;
    try {
      return Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  DateTime? _lastBack;
  // v2.4.3 fix: 之前在 build() 里 new MonitorStore()，build 一次就 new 一次。
  // 搬到 initState 后整个 App 生命周期只有一份 store + 一组 polling timer。
  late final MonitorStore _store;

  /// 双击返回退出：第一次按提示「再按一次回到桌面」(toast)，2 秒内再按才真退出。
  /// v2.4.3: 仅在总览页生效；详情页按下时直接 selectOverview() 回总览。
  /// v2.4.5: 接收 [ctx] 参数，因为 build() 的 context 是 State 的 context，
  /// 它的位置在 MaterialApp 之上，找不到 MaterialApp 内部的 rootOverlay。
  /// 调用方需要从 home: 里的 Builder 取一个 innerContext 传进来。
  ///
  /// 重做：之前用自造 AppToast（基于 OverlayEntry）显示「再按一次返回桌面」，
  /// 但 release 渲染 / Overlay 边界 / 自造 Container 都有"黄线"等视觉 bug 风险。
  /// 改用 Flutter 标准 ScaffoldMessenger + SnackBar（系统组件 + 系统定位 + 系统动画）：
  ///   - 不会出现"两条黄线"等自造 widget 边界问题
  ///   - duration 改成 2 秒，跟 _handleBack 时间窗口 2000ms 对齐（之前 toast 1.5s 太短，
  ///     用户看到 toast 消失后再按可能踩 2s 边界误判）
  bool _handleBack(BuildContext ctx) {
    final now = DateTime.now();
    if (_lastBack != null &&
        now.difference(_lastBack!).inMilliseconds < 2000) {
      return true; // 允许退出
    }
    _lastBack = now;
    ScaffoldMessenger.of(ctx).showSnackBar(
      const SnackBar(
        content: Text('再按一次返回桌面'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.fixed,  // 不用 floating 避免自造 border
      ),
    );
    return false; // 阻止退出
  }

  @override
  void initState() {
    super.initState();
    _store = MonitorStore();
    // Fire-and-forget: start loads persisted servers + starts polling.
    // Bug #8 fix: use the real unawaited() from dart:async (was a no-op
    // stub that swallowed the Future, here for documentation).
    unawaited(_store.start());
  }

  @override
  Widget build(BuildContext context) {
    // v2.4.26+: iOS 27 液态玻璃 UI
    if (_isIOS) {
      return CupertinoApp(
        title: '星黎监控',
        debugShowCheckedModeBanner: false,
        theme: const CupertinoThemeData(
          primaryColor: ios_theme.IOSTheme.primary,
          brightness: Brightness.light,  // v2.4.26+: 改成 light（粉色+白主题需要 dark text on light bg）
        ),
        home: IOSApp(store: _store),
      );
    }
    return MaterialApp(
      title: '星黎监控',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFFF6B95),
        brightness: Brightness.light,
      ).copyWith(
        primary: const Color(0xFFFF6B95),
        secondary: const Color(0xFFFFB6C1),
        surface: Colors.white.withOpacity(0.55),
        onSurface: const Color(0xFF2C2C2C),
      ),
      scaffoldBackgroundColor: const Color(0xFFFFEEF2),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Color(0xFF2C2C2C),
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
        iconTheme: IconThemeData(color: Color(0xFF2C2C2C)),
        actionsIconTheme: IconThemeData(color: Color(0xFF2C2C2C)),
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: Color(0xFF2C2C2C)),
        bodyMedium: TextStyle(color: Color(0xFF2C2C2C)),
        bodySmall: TextStyle(color: Color(0xFF7A7A82)),
        titleMedium: TextStyle(color: Color(0xFF1A1A1A), fontWeight: FontWeight.w600),
        titleLarge: TextStyle(color: Color(0xFF1A1A1A), fontWeight: FontWeight.w700),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xF2FFFFFF),
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: const Color(0x33FF6B95),
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(16)),
          side: const BorderSide(color: Color(0x33FFB6C1), width: 0.6),
        ),
        textStyle: const TextStyle(color: Color(0xFF2C2C2C), fontSize: 14),
        iconColor: const Color(0xFFFF6B95),
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0x22000000),
        thickness: 0.5,
        space: 0.5,
      ),
    ),
    // v2.4.4 fix: PopScope 必须包在 home route 里面才能拦到那个 route 的
    // 返回手势。之前放在 MaterialApp 外层是 NO-OP，home route 没有任何
    // PopScope 祖先 → 用户按返回直接弹 home route = 退到桌面。
    //
    // v2.4.5 fix: 用 Builder 包一层拿一个"在 home route 内部"的 context。
    // 之前 build() 的 context 是 State 的 element 的 context，位置在
    // MaterialApp 之上 → 找不到 MaterialApp 内部的 rootOverlay
    // (Overlay.maybeOf 返回 null，AppToast 静默 drop)。Builder 的
    // context 已经在 route 内部，Overlay / Navigator 都能正常找到。
    home: StoreScope(
      store: _store,
      child: Builder(
        builder: (innerContext) => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            // 详情页 → 按返回回总览页
            if (!_store.isOverview) {
              _store.selectOverview();
              return;
            }
            // 总览页 → 双击退
            if (_handleBack(innerContext)) {
              // 第二次按了 → 真退出
              // Bug fix: 之前用 Navigator.of().pop() 只 pop 了 route，留个空
              // Navigator 渲染黑屏，要再按一次返回才真正关 activity。换成
              // SystemNavigator.pop() 直接发系统 back press 让 OS 关掉
              // FlutterActivity。两次返回直达桌面。
              SystemNavigator.pop();
            }
          },
          child: const HomePage(),
        ),
      ),
    ),
    );
  }
}

class StoreScope extends StatelessWidget {
  final MonitorStore store;
  final Widget child;
  const StoreScope({super.key, required this.store, required this.child});

  @override
  Widget build(BuildContext context) {
    return MonitorScope(store: store, child: child);
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // v2.4.3：首次启动自动弹「添加服务器」对话框。
  // 用 SharedPreferences 持久化"已经弹过"标记，弹完即置 true，
  // 后续用户删完所有 server 也不会再弹。
  bool _firstLaunchChecked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkFirstLaunch();
    });
  }

  Future<void> _checkFirstLaunch() async {
    if (_firstLaunchChecked) return;
    final store = context.monitor;
    // 等 store.start() 跑完（首次冷启 SharedPreferences 还要读盘）
    while (!store.firstLoadDone) {
      await Future.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
    }
    _firstLaunchChecked = true;
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool('first_launch_shown') ?? false;
    if (!shown && mounted && store.orderedServers.isEmpty) {
      await prefs.setBool('first_launch_shown', true);
      if (mounted) {
        await AddServerDialog.show(context, store);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.monitor;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: GlassAppBar(
            title: _ServerSelector(store: store),
            actions: [
              _AboutButton(),
              if (ErrorDetailsPage.hasErrors(store))
                _ErrorIndicatorButton(store: store),
              _AddButton(store: store),
              if (store.isLoading)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: Center(
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF6B95)),
                    ),
                  ),
                ),
            ],
          ),
          body: Stack(
            children: [
              const _GradientBackdrop(),
              SafeArea(
                child: _bodyFor(store),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _bodyFor(MonitorStore store) {
    if (store.isOverview) {
      return OverviewPage(store: store);
    }
    return DynamicServerPage(server: store.currentServer!, store: store);
  }
}

class _AddButton extends StatelessWidget {
  final MonitorStore store;
  const _AddButton({required this.store});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showAdd(context),
          borderRadius: BorderRadius.circular(20),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 22, color: Color(0xFFFF6B95)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showAdd(BuildContext context) async {
    final s = await AddServerDialog.show(context, store);
    if (s != null) {
      store.selectServer(s);
    }
  }
}

class _AboutButton extends StatelessWidget {
  const _AboutButton();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => AboutPage.show(context),
          borderRadius: BorderRadius.circular(20),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Icon(Icons.info_outline_rounded, size: 20, color: Color(0xFF7A7A82)),
          ),
        ),
      ),
    );
  }
}

/// AppBar 上的错误指示器：红 icon + 角标，点了进 ErrorDetailsPage。
/// 没有错误时 main.dart 不渲染这个 widget，不用考虑。
class _ErrorIndicatorButton extends StatelessWidget {
  final MonitorStore store;
  const _ErrorIndicatorButton({required this.store});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ErrorDetailsPage(store: store),
            ));
          },
          borderRadius: BorderRadius.circular(20),
          child: Tooltip(
            message: '查看错误',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 20,
                    color: Color(0xFFE53935),
                  ),
                  // 右上角红点提示有错误
                  Positioned(
                    top: -2,
                    right: -3,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE53935),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Gradient backdrop — soft white + sakura pink.
class _GradientBackdrop extends StatelessWidget {
  const _GradientBackdrop();
  @override
  Widget build(BuildContext context) {
    return const Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFFFFFFF), // pure white
              Color(0xFFFFE4EC), // soft sakura
              Color(0xFFFFF0F5), // pale blush
              Color(0xFFFFFFFF), // back to white
            ],
            stops: [0.0, 0.35, 0.7, 1.0],
          ),
        ),
      ),
    );
  }
}

/// Translucent AppBar with backdrop blur (frosted) or solid white + shadow (solid).
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget title;
  final List<Widget> actions;
  const GlassAppBar({super.key, required this.title, this.actions = const []});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final isSolid = const String.fromEnvironment('GLASS_STYLE', defaultValue: 'frosted') == 'solid';
    if (isSolid) {
      return Container(
        decoration: const BoxDecoration(
          color: Color(0xFFFFFFFF),
          border: Border(
            bottom: BorderSide(color: Color(0xFFE5E5EA), width: 0.5),
          ),
          boxShadow: const [
            BoxShadow(color: Color(0x12000000), blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
        child: SafeArea(
          bottom: false,
          child: AppBar(
            title: title,
            actions: actions,
            automaticallyImplyLeading: false,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
          ),
        ),
      );
    }
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0x59FFFFFF),
            border: Border(
              bottom: BorderSide(color: Color(0x30FFB6C1), width: 0.5),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: AppBar(
              title: title,
              actions: actions,
              automaticallyImplyLeading: false,
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerSelector extends StatelessWidget {
  final MonitorStore store;
  const _ServerSelector({required this.store});

  @override
  Widget build(BuildContext context) {
    final label = store.isOverview ? '总览' : (store.currentServer?.name ?? '?');
    final servers = store.orderedServers;
    return PopupMenuButton<String>(
      tooltip: '切换服务器',
      onSelected: (key) {
        if (key == '__overview__') {
          store.selectOverview();
        } else {
          final s = servers.firstWhere(
            (s) => s.id == key,
            orElse: () => servers.first,
          );
          store.selectServer(s);
        }
      },
      position: PopupMenuPosition.under,
      itemBuilder: (ctx) => [
        const PopupMenuItem(
          value: '__overview__',
          child: Row(
            children: [
              Icon(Icons.dashboard_rounded, size: 18, color: Color(0xFFFF6B95)),
              SizedBox(width: 10),
              Text('总览', style: TextStyle(color: Color(0xFF2C2C2C), fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        for (final s in servers)
          PopupMenuItem<String>(
            value: s.id,
            child: Row(
              children: [
                Icon(
                  s.isSsh ? Icons.terminal_rounded : Icons.http_rounded,
                  size: 18,
                  color: (store.currentServer?.id == s.id)
                      ? const Color(0xFFFF6B95)
                      : const Color(0xFF7A7A82),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(s.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: const Color(0xFF2C2C2C),
                        fontWeight: (store.currentServer?.id == s.id)
                            ? FontWeight.w700
                            : FontWeight.w400,
                      )),
                ),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF2C2C2C), letterSpacing: 0.2)),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down_rounded, color: Color(0xFF2C2C2C)),
          ],
        ),
      ),
    );
  }
}
