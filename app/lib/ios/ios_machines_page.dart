// iOS 风格机器列表页
//
// 跟安卓 overview_page.dart 对齐：手动排序 + iOS-Home-Screen 风格 sort mode +
// 错误整页 + "更新于" 时间戳 + NAS/VPS chip + 温度/GPU/磁盘/客户端 mini stat +
// 空状态大按钮 + 底部刷新时间戳。
//
// 视觉保持 iOS 27 Liquid Glass（GlassContainer + BackdropFilter），
// 行为/信息密度跟安卓一致。

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show LinearProgressIndicator;

import '../models.dart';
import '../store.dart';
import 'ios_helpers.dart';
import 'ios_theme.dart';
import 'ios_glass.dart';

class IOSMachinesPage extends StatefulWidget {
  final MonitorStore store;
  const IOSMachinesPage({super.key, required this.store});

  @override
  State<IOSMachinesPage> createState() => _IOSMachinesPageState();
}

class _IOSMachinesPageState extends State<IOSMachinesPage> {
  // ----- Drag state（跟安卓 overview_page.dart 同一套：手写拖拽 + Stack 浮卡）-----
  int? _draggingIndex;
  Offset? _dragCardStartGlobal;
  Offset? _dragFingerStartGlobal;
  Offset? _dragFingerCurrentGlobal;
  Size? _dragCardSize;
  int? _hoverIndex;
  final Map<String, GlobalKey> _cardKeys = {};
  final GlobalKey _stackKey = GlobalKey();

  // ----- Sort mode（v2.4.1 iOS-Home-Screen 风格）-----
  bool _isSortMode = false;

  MonitorStore get store => widget.store;

  @override
  Widget build(BuildContext context) {
    final servers = store.orderedServers;
    final data = store.data;
    final hasServers = servers.isNotEmpty;
    final hasData = data.isNotEmpty;

    // 错误整页：跟安卓一致 —— store.error 有 + 还没拉到任何数据 = 整页错误
    if (store.error != null && store.error!.isNotEmpty && !hasData) {
      return _ErrorView(message: store.error!, onRetry: () => store.retryAll());
    }

    return Stack(
      key: _stackKey,
      children: [
        // iOS 27 风格紧凑顶部：SafeArea + CupertinoNavigationBar（不带大标题）+ 内容
        Column(
          children: [
            // 顶部导航条：紧凑（44px）替代之前的大标题（96px+）
            CupertinoNavigationBar(
              backgroundColor: const Color(0xFFFFFFFF),
              border: null,
              padding: const EdgeInsetsDirectional.only(start: 8, end: 8),
              leading: null,
              middle: const Text(
                '总览',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: IOSTheme.textPrimary,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (store.isLoading)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: CupertinoActivityIndicator(radius: 9),
                    ),
                  // 错误指示器（store.error 存在时显示红 icon + 角标）
                  if (store.error != null && store.error!.isNotEmpty)
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minSize: 32,
                      onPressed: () {
                        Navigator.of(context).pushNamed('/error-details');
                      },
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Icon(
                            CupertinoIcons.exclamationmark_circle,
                            color: IOSTheme.danger,
                            size: 20,
                          ),
                          Positioned(
                            top: -2,
                            right: -3,
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: IOSTheme.danger,
                                shape: BoxShape.circle,
                                border: Border.all(color: const Color(0xFFFFFFFF), width: 1.2),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 32,
                    onPressed: store.refresh,
                    child: const Icon(CupertinoIcons.refresh, color: IOSTheme.primary, size: 20),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 32,
                    onPressed: _openAddPage,
                    child: const Icon(CupertinoIcons.add_circled, color: IOSTheme.primary, size: 22),
                  ),
                ],
              ),
            ),
            // 内容区
            Expanded(
              child: _buildContent(hasServers, hasData, servers),
            ),
          ],
        ),
        // 浮卡预览（拖动时显示）
        if (_draggingIndex != null) _buildFloatingCard(),
        // 排序模式 banner
        if (_isSortMode && _draggingIndex == null) _buildSortModeBanner(),
      ],
    );
  }

  Widget _buildContent(bool hasServers, bool hasData, List<MonitorServer> servers) {
    if (!hasServers) {
      return const _EmptyView();
    }
    if (!hasData) {
      // 有 server 注册但还没拉到数据 → 轻转圈
      return const Center(child: CupertinoActivityIndicator(radius: 14));
    }
    // ListView（去掉 sliver，直接用普通 ListView + ListView.builder）
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        IOSTheme.paddingL, IOSTheme.paddingS,
        IOSTheme.paddingL, 140,  // 留出浮动 tab bar 空间
      ),
      itemCount: servers.length + 1,  // +1 for "更新于" timestamp at bottom
      itemBuilder: (ctx, i) {
        if (i < servers.length) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _buildCardSlot(i),
          );
        }
        // 最后一个 item：底部"更新于"时间戳
        if (store.lastSuccessAt != null) {
          return Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 24),
            child: Center(
              child: Text(
                '更新于 ${fmtTime(store.lastSuccessAt!)}',
                style: const TextStyle(
                  color: IOSTheme.textTertiary,
                  fontSize: 11,
                ),
              ),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  // ============================================================
  // Card slot（带 sort mode 动画 + 拖动 offset 偏移）
  // ============================================================
  Widget _buildCardSlot(int i) {
    final servers = store.orderedServers;
    final server = servers[i];
    _cardKeys.putIfAbsent(server.id, () => GlobalKey());
    final isDragging = _draggingIndex == i;

    // v2.4.2：把"中间"的卡挤开给拖动卡让位置
    double targetDy = 0;
    if (_draggingIndex != null &&
        _hoverIndex != null &&
        _draggingIndex != _hoverIndex &&
        !isDragging) {
      final slotHeight = (_dragCardSize?.height ?? 100) + 12;
      final from = _draggingIndex!;
      final to = _hoverIndex!;
      if (from < to) {
        if (i > from && i <= to) targetDy = -slotHeight;
      } else {
        if (i >= to && i < from) targetDy = slotHeight;
      }
    }

    final data = store.data[server.id];
    final error = store.errorFor(server);
    final lastSuccessMs = store.lastSuccessFor(server)?.millisecondsSinceEpoch;
    final status = computeStatus(lastSuccessMs);

    Widget card = _ServerCard(
      key: _cardKeys[server.id],
      server: server,
      data: data,
      error: error,
      status: status,
      onRetry: () => store.pollServer(server),
    );

    Widget slot = card;

    if (_draggingIndex != null && targetDy != 0) {
      slot = TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: targetDy),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        builder: (ctx, dy, child) => Transform.translate(offset: Offset(0, dy), child: child),
        child: card,
      );
    } else if (_isSortMode && _draggingIndex == null && !isDragging) {
      slot = _ShakeAnimation(enabled: true, child: card);
    }

    // 拖动中的源卡半透明
    if (isDragging) {
      slot = AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: 0.25,
        child: slot,
      );
    }

    // sort mode 下整张卡换成"长按 = 拖动"；非 sort mode 下点 = 进 detail，
    // 长按 = 弹菜单
    if (isFloating(i)) return slot;
    if (_isSortMode) {
      return GestureDetector(
        onLongPressStart: (d) => _onCardDragStart(i, d.globalPosition),
        onLongPressMoveUpdate: (d) => _onCardDragUpdate(d.globalPosition),
        onLongPressEnd: (_) => _onCardDragEnd(),
        child: slot,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pushNamed('/detail', arguments: server),
      onLongPress: () => _showServerMenu(server),
      child: slot,
    );
  }

  bool isFloating(int i) => false; // 真实浮卡走 _buildFloatingCard，slot 都不是 floating

  // ============================================================
  // Sort mode banner（顶部"完成"条）
  // ============================================================
  Widget _buildSortModeBanner() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 60,
      left: IOSTheme.paddingL,
      right: IOSTheme.paddingL,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: IOSTheme.primary.withOpacity(0.18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: IOSTheme.primary.withOpacity(0.5), width: 0.6),
        ),
        child: Row(
          children: [
            const Icon(CupertinoIcons.arrow_up_arrow_down, size: 16, color: IOSTheme.primary),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '排序模式：长按卡片拖动调整顺序',
                style: TextStyle(
                  color: IOSTheme.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              color: IOSTheme.primary,
              borderRadius: BorderRadius.circular(10),
              minSize: 0,
              onPressed: _exitSortMode,
              child: const Text(
                '完成',
                style: TextStyle(color: CupertinoColors.white, fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // Drag handlers
  // ============================================================
  void _onCardDragStart(int index, Offset fingerGlobal) {
    final cardKey = _cardKeys[store.orderedServers[index].id];
    if (cardKey == null) return;
    final ctx = cardKey.currentContext;
    if (ctx == null) return;
    final renderBox = ctx.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached) return;
    setState(() {
      _draggingIndex = index;
      _dragCardStartGlobal = renderBox.localToGlobal(Offset.zero);
      _dragCardSize = renderBox.size;
      _dragFingerStartGlobal = fingerGlobal;
      _dragFingerCurrentGlobal = fingerGlobal;
      _hoverIndex = index;
    });
  }

  void _onCardDragUpdate(Offset fingerGlobal) {
    if (_draggingIndex == null) return;
    setState(() {
      _dragFingerCurrentGlobal = fingerGlobal;
      _updateHoverIndex();
    });
  }

  void _onCardDragEnd() {
    final draggingIndex = _draggingIndex;
    final hoverIndex = _hoverIndex;
    setState(() {
      _draggingIndex = null;
      _dragCardStartGlobal = null;
      _dragFingerStartGlobal = null;
      _dragFingerCurrentGlobal = null;
      _dragCardSize = null;
      _hoverIndex = null;
    });
    if (draggingIndex != null && hoverIndex != null && draggingIndex != hoverIndex) {
      store.reorderServers(draggingIndex, hoverIndex);
    }
  }

  void _enterSortMode() {
    setState(() => _isSortMode = true);
  }

  void _exitSortMode() {
    setState(() {
      _isSortMode = false;
      _draggingIndex = null;
      _dragCardStartGlobal = null;
      _dragFingerStartGlobal = null;
      _dragFingerCurrentGlobal = null;
      _dragCardSize = null;
      _hoverIndex = null;
    });
  }

  void _updateHoverIndex() {
    if (_dragFingerCurrentGlobal == null) return;
    final fingerY = _dragFingerCurrentGlobal!.dy;
    final servers = store.orderedServers;
    int newHover = _draggingIndex ?? 0;
    for (int i = 0; i < servers.length; i++) {
      if (i == _draggingIndex) continue;
      final key = _cardKeys[servers[i].id];
      final ctx = key?.currentContext;
      if (ctx == null) continue;
      final rb = ctx.findRenderObject() as RenderBox?;
      if (rb == null || !rb.attached) continue;
      final topY = rb.localToGlobal(Offset.zero).dy;
      final midY = topY + rb.size.height / 2;
      if (fingerY < midY) {
        newHover = i;
        break;
      } else {
        newHover = i + 1;
      }
    }
    _hoverIndex = newHover;
  }

  Widget _buildFloatingCard() {
    final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null) return const SizedBox.shrink();
    if (_dragCardStartGlobal == null ||
        _dragFingerStartGlobal == null ||
        _dragFingerCurrentGlobal == null ||
        _dragCardSize == null ||
        _draggingIndex == null) {
      return const SizedBox.shrink();
    }
    final stackTopLeft = stackBox.localToGlobal(Offset.zero);
    final cardLocalX = _dragCardStartGlobal!.dx - stackTopLeft.dx;
    final cardLocalY = (_dragCardStartGlobal!.dy +
            (_dragFingerCurrentGlobal!.dy - _dragFingerStartGlobal!.dy)) -
        stackTopLeft.dy;
    final server = store.orderedServers[_draggingIndex!];
    final data = store.data[server.id];
    final error = store.errorFor(server);
    final lastSuccessMs = store.lastSuccessFor(server)?.millisecondsSinceEpoch;
    final status = computeStatus(lastSuccessMs);
    return Positioned(
      left: cardLocalX,
      top: cardLocalY,
      width: _dragCardSize!.width,
      height: _dragCardSize!.height,
      child: IgnorePointer(
        child: Transform.scale(
          scale: 1.04,
          alignment: Alignment.topLeft,
          child: Opacity(
            opacity: 0.92,
            child: _ServerCard(
              server: server,
              data: data,
              error: error,
              status: status,
              onRetry: () {},
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // Server context menu（长按弹，跟安卓 _ServerMenu 对齐）
  // ============================================================
  Future<void> _showServerMenu(MonitorServer s) async {
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(s.name),
        message: Text('${s.host}:${s.port}'),
        actions: [
          if (store.orderedServers.length > 1)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'sort'),
              child: const Text('排序'),
            ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'view'),
            child: const Text('查看详情'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'edit'),
            child: const Text('编辑'),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('删除服务器'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx, 'cancel'),
          child: const Text('取消'),
        ),
      ),
    );
    if (!mounted || action == null || action == 'cancel') return;
    if (action == 'sort') {
      _enterSortMode();
    } else if (action == 'view') {
      Navigator.of(context).pushNamed('/detail', arguments: s);
    } else if (action == 'edit') {
      await Navigator.of(context).pushNamed('/add', arguments: s);
    } else if (action == 'delete') {
      final ok = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('删除服务器'),
          content: Text('确认删除「${s.name}」？\n仅从本应用移除。'),
          actions: [
            CupertinoDialogAction(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (ok == true) {
        await store.deleteServer(s.id);
      }
    }
  }

  void _openAddPage() {
    Navigator.of(context).pushNamed('/add');
  }
}

// ============================================================
// Empty view — 跟安卓的 _EmptyView 对齐：图标 + 文案 + "添加服务器"大按钮
// ============================================================
class _EmptyView extends StatelessWidget {
  const _EmptyView();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [IOSTheme.primary, IOSTheme.primaryLight],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(CupertinoIcons.desktopcomputer, color: CupertinoColors.white, size: 32),
            ),
            const SizedBox(height: 16),
            const Text(
              '还没有服务器',
              style: TextStyle(
                color: IOSTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '点击右上角 + 按钮，添加你的第一台服务器',
              style: TextStyle(color: IOSTheme.textTertiary, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              onPressed: () => Navigator.of(context).pushNamed('/add'),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.add, size: 18),
                  SizedBox(width: 6),
                  Text('添加服务器'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Error view — 跟安卓的 _ErrorView 对齐：图标 + 报错 + 重试按钮
// ============================================================
class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(CupertinoIcons.cloud_bolt, color: IOSTheme.danger, size: 56),
            const SizedBox(height: 12),
            const Text(
              '连不上服务器',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: IOSTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: IOSTheme.textTertiary, fontSize: 12),
            ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              onPressed: onRetry,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.refresh, size: 16),
                  SizedBox(width: 6),
                  Text('重试'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Server card — 跟安卓 _ServerCard 行为对齐：
//   - NAS/VPS icon + 名字 + 状态徽章（用 lastSuccessMs 算）
//   - CPU/内存 UsageBar（mini 横向条）
//   - 温度 / GPU util / GPU temp / 磁盘 / xui 客户端 mini chip
//   - 错误态卡片：云断开 icon + 错误信息 + 单独重试按钮
// ============================================================
class _ServerCard extends StatelessWidget {
  final MonitorServer server;
  final AgentData? data;
  final String? error;
  final ServerStatus status;
  final VoidCallback onRetry;
  const _ServerCard({
    super.key,
    required this.server,
    required this.data,
    required this.error,
    required this.status,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final hw = data?.hardware;
    final cpu = hw?.cpu;
    final mem = hw?.memory;
    final gpu = hw?.gpu;
    final disks = hw?.disks ?? const <DiskEntry>[];
    final temp = cpu?.tempC ?? 0;
    final isVps = data?.kind == 'vps' || data?.xui != null;
    final hasXui = data?.xui != null;

    // 错误态：data == null + error 有 → 错误卡
    if (data == null && error != null && error!.isNotEmpty) {
      return GlassContainer(
        padding: const EdgeInsets.all(IOSTheme.paddingL),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isVps ? CupertinoIcons.globe : CupertinoIcons.desktopcomputer,
                  size: 18,
                  color: IOSTheme.danger,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    server.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: IOSTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _RetryChip(onRetry: onRetry),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(CupertinoIcons.cloud_bolt, size: 12, color: IOSTheme.danger),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: IOSTheme.danger,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return GlassContainer(
      padding: const EdgeInsets.all(IOSTheme.paddingL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部：NAS/VPS icon + 名字 + 状态徽章
          Row(
            children: [
              Icon(
                isVps ? CupertinoIcons.globe : CupertinoIcons.desktopcomputer,
                size: 18,
                color: IOSTheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  server.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: IOSTheme.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              StatusPill(status: status),
            ],
          ),
          const SizedBox(height: 10),
          // data == null → "暂无数据（首次拉取中）"
          if (data == null) ...[
            const Text(
              '暂无数据（首次拉取中）',
              style: TextStyle(color: IOSTheme.textTertiary, fontSize: 12),
            ),
          ] else if (hw == null) ...[
            const Text(
              '暂无硬件数据',
              style: TextStyle(color: IOSTheme.textTertiary, fontSize: 12),
            ),
          ] else ...[
            // CPU + 内存 横向 UsageBar
            Row(
              children: [
                Expanded(
                  child: _MiniUsageBar(
                    label: 'CPU',
                    value: cpu != null ? '${cpu.percent.toStringAsFixed(1)}%' : '—',
                    percent: cpu?.percent ?? 0,
                    color: cpu != null ? usageColor(cpu.percent) : IOSTheme.textTertiary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MiniUsageBar(
                    label: '内存',
                    value: mem != null ? '${mem.percent.toStringAsFixed(0)}%' : '—',
                    percent: mem?.percent ?? 0,
                    color: mem != null ? usageColor(mem.percent) : IOSTheme.textTertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // 温度 / GPU / 磁盘 / xui 客户端 mini chip
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                _MiniStat(
                  icon: CupertinoIcons.thermometer,
                  label: '温度',
                  value: temp > 0 ? '${temp.toStringAsFixed(0)}°C' : '—',
                  color: temp > 0 ? tempColor(temp) : null,
                ),
                if (gpu != null && gpu.hasUtil)
                  _MiniStat(
                    icon: CupertinoIcons.gauge,
                    label: 'GPU',
                    value: '${gpu.percent!.toStringAsFixed(0)}%',
                    color: usageColor(gpu.percent!),
                  ),
                if (gpu != null && gpu.hasTemp)
                  _MiniStat(
                    icon: CupertinoIcons.thermometer,
                    label: '显卡',
                    value: '${gpu.tempC!.toStringAsFixed(0)}°C',
                    color: tempColor(gpu.tempC!),
                  ),
                if (disks.isNotEmpty)
                  _MiniStat(
                    icon: CupertinoIcons.archivebox,
                    label: '磁盘',
                    value: '${disks.first.percent.toStringAsFixed(0)}%',
                    color: usageColor(disks.first.percent),
                  ),
                if (hasXui)
                  _MiniStat(
                    icon: CupertinoIcons.person_2,
                    label: '客户端',
                    value: '${data!.xui!.onlineCount}/${data!.xui!.totalClients}',
                    color: IOSTheme.primary,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// 错误卡上的"重试"按钮
class _RetryChip extends StatefulWidget {
  final VoidCallback onRetry;
  const _RetryChip({required this.onRetry});
  @override
  State<_RetryChip> createState() => _RetryChipState();
}

class _RetryChipState extends State<_RetryChip> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _busy
          ? null
          : () async {
              setState(() => _busy = true);
              try {
                widget.onRetry();
                // 简单给 1.2s 反馈时间，不 await store.pollServer
                // （store 是异步 fire-and-forget 模式）
                await Future.delayed(const Duration(milliseconds: 1200));
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: IOSTheme.danger.withOpacity(0.18),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: IOSTheme.danger.withOpacity(0.4), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy)
              const CupertinoActivityIndicator(radius: 6)
            else
              const Icon(CupertinoIcons.refresh, size: 12, color: IOSTheme.danger),
            const SizedBox(width: 4),
            const Text('重试', style: TextStyle(color: IOSTheme.danger, fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

// mini usage bar（iOS 27 风格：玻璃条 + gradient fill）
class _MiniUsageBar extends StatelessWidget {
  final String label;
  final String value;
  final double percent;
  final Color color;
  const _MiniUsageBar({required this.label, required this.value, required this.percent, required this.color});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: IOSTheme.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
              ),
            ),
            const Spacer(),
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // v2.4.28+：用 LinearProgressIndicator（跟安卓 UsageBar 一样），
        // 之前手画的 Container+FractionallySizedBox 渐变 fill 0.7 alpha 会
        // 跟 track 颜色叠在一起糊掉，看不到总条
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (percent.clamp(0, 100)) / 100,
            minHeight: 8,
            backgroundColor: IOSTheme.trackBackground,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }
}

// mini stat chip
class _MiniStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;
  const _MiniStat({required this.icon, required this.label, required this.value, this.color});
  @override
  Widget build(BuildContext context) {
    final c = color ?? IOSTheme.textTertiary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: c),
        const SizedBox(width: 3),
        Text(
          '$label $value',
          style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 12),
        ),
      ],
    );
  }
}

// ============================================================
// Shake animation（sort mode 下非正在拖的卡晃动）
// ============================================================
class _ShakeAnimation extends StatefulWidget {
  final Widget child;
  final bool enabled;
  const _ShakeAnimation({required this.child, required this.enabled});
  @override
  State<_ShakeAnimation> createState() => _ShakeAnimationState();
}

class _ShakeAnimationState extends State<_ShakeAnimation> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final double _phaseOffset;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
    _phaseOffset = (widget.child.hashCode % 1000) / 1000.0 * 2 * math.pi;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _ShakeAnimation old) {
    super.didUpdateWidget(old);
    if (widget.enabled != old.enabled) _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.enabled) {
      _ctrl.repeat(reverse: true);
    } else {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final angle = math.sin((_ctrl.value * 2 * math.pi) + _phaseOffset) * 0.012;
        return Transform.rotate(angle: angle, child: child);
      },
      child: widget.child,
    );
  }
}
