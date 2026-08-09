// Overview page: one glass card per registered server, plus a "add another"
// hint if the list is empty. Tapping a card navigates to that server's
// detail page. Long-pressing a card opens a context menu.
//
// Reorder flow (v2.4.1, iOS-Home-Screen style): the menu has a "排序" entry
// that puts every card into a wiggle / shake animation and re-binds the
// card-wide long-press to drag-to-reorder (the menu is suppressed in that
// mode). A "完成" banner at the top of the list exits the mode.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'add_server_dialog.dart';
import 'models.dart';
import 'store.dart';
import 'widgets.dart';

class OverviewPage extends StatefulWidget {
  final MonitorStore store;
  const OverviewPage({super.key, required this.store});

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  // ----- Drag state (hand-rolled drag-to-reorder, v2.4.0) -----
  // All card positions are captured in screen-global coordinates so the
  // floating preview can be positioned via the Stack's RenderBox regardless
  // of how the ListView scrolls. v2.4.2 dropped the drop-indicator line in
  // favour of actually pushing the other cards out of the way (transform
  // translate), which is far more obvious.
  int? _draggingIndex;
  Offset? _dragCardStartGlobal; // top-left of the source card at drag start
  Offset? _dragFingerStartGlobal; // finger position at drag start
  Offset? _dragFingerCurrentGlobal; // current finger position (updated on move)
  Size? _dragCardSize; // size of the source card
  int? _hoverIndex; // "insert before this index" — equals N means "append"

  // GlobalKey per card (keyed by stable server.id) so we can look up each
  // card's RenderBox during a drag to compute hover position.
  final Map<String, GlobalKey> _cardKeys = {};
  // GlobalKey on the Stack (so we can convert screen-global <-> Stack-local
  // coordinates for the floating card and drop indicator).
  final GlobalKey _stackKey = GlobalKey();

  // ----- Sort mode (v2.4.1, iOS-Home-Screen style edit mode) -----
  // Entered from the card's long-press menu ("排序" entry). While in sort
  // mode every non-dragging card wiggles (±0.7° rotation, ~300ms period) and
  // the card-wide long-press re-binds from "open menu" to "start drag".
  bool _isSortMode = false;

  // ----- Public API preserved -----
  MonitorStore get store => widget.store;

  @override
  Widget build(BuildContext context) {
    if (store.error != null && store.data.isEmpty) {
      return _ErrorView(message: store.error!, onRetry: () => store.retryAll());
    }
    if (store.servers.isEmpty) {
      return _EmptyView(store: store);
    }
    if (store.data.isEmpty && store.servers.isNotEmpty) {
      // We have servers registered but no live data yet — show a light
      // spinner instead of the full-screen error.
      return const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B95)));
    }

    return Stack(
      key: _stackKey,
      children: [
        _buildList(),
        // Floating card preview that follows the finger
        if (_draggingIndex != null) _buildFloatingCard(),
      ],
    );
  }

  // ----- List (the same content as v2.3.0, just wrapped in a builder) -----
  Widget _buildList() {
    return RefreshIndicator(
      color: const Color(0xFFFF6B95),
      backgroundColor: Colors.white,
      onRefresh: () async => Future.delayed(const Duration(milliseconds: 500)),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // 错误提示挪到 AppBar 右上角红 icon + 错误详情页（v2.4.16）
          // 排序模式 banner：iOS 主屏编辑风格的"完成"条。仅在 sort mode 时显示。
          if (_isSortMode) _buildSortModeBanner(),
          for (int i = 0; i < store.orderedServers.length; i++)
            _buildCardSlot(i),
          const SizedBox(height: 8),
          if (store.lastSuccessAt != null)
            Center(
              key: const ValueKey('last-success'),
              child: Text(
                '更新于 ${_fmtTime(store.lastSuccessAt!)}',
                style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCardSlot(int i) {
    final server = store.orderedServers[i];
    // Allocate a GlobalKey for this card on first render; reused on rebuilds.
    _cardKeys.putIfAbsent(server.id, () => GlobalKey());
    final isDragging = _draggingIndex == i;

    // v2.4.2：计算这张卡需要偏移多少，让"中间"的卡真的让位置给拖动卡。
    // 例如拖 index=1 的卡往下到 index=3，则 index 2、3 各自往上挪一格；
    // 反之拖 index=3 的卡往上到 index=1，则 index 1、2 各自往下挪一格。
    // 用 dragging 卡的高度 + 10px padding 作为一格的位移量。
    double targetDy = 0;
    if (_draggingIndex != null &&
        _hoverIndex != null &&
        _draggingIndex != _hoverIndex &&
        !isDragging) {
      final slotHeight = (_dragCardSize?.height ?? 100) + 10;
      final from = _draggingIndex!;
      final to = _hoverIndex!;
      if (from < to) {
        // 向下拖：中间 (from, to] 区间内的卡往上挤 -slotHeight
        if (i > from && i <= to) targetDy = -slotHeight;
      } else {
        // 向上拖：中间 [to, from) 区间内的卡往下挤 +slotHeight
        if (i >= to && i < from) targetDy = slotHeight;
      }
    }

    final slot = Padding(
      key: ValueKey('slot-${server.id}'),
      padding: const EdgeInsets.only(bottom: 10),
      // Ghost effect on the source card so user can see what's being moved.
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: isDragging ? 0.25 : 1.0,
        child: _ServerCard(
          // GlobalKey lets us look up the card's RenderBox during drag.
          key: _cardKeys[server.id],
          server: server,
          store: store,
          isFloating: false,
          isSortMode: _isSortMode,
          onEnterSortMode: _enterSortMode,
          onDragStart: (fingerGlobal) => _onCardDragStart(i, fingerGlobal),
          onDragUpdate: _onCardDragUpdate,
          onDragEnd: _onCardDragEnd,
        ),
      ),
    );

    // 拖动中且需要偏移：套 TweenAnimationBuilder 让位移是丝滑的过渡而不是瞬移
    if (_draggingIndex != null && targetDy != 0) {
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: targetDy),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        builder: (context, dy, child) =>
            Transform.translate(offset: Offset(0, dy), child: child),
        child: slot,
      );
    }

    // 排序模式下：非正在拖的卡套上 iOS 抖动（被拖的那张不抖，避免和悬浮预览打架）
    if (_isSortMode && _draggingIndex == null && !isDragging) {
      return _ShakeAnimation(enabled: true, child: slot);
    }
    return slot;
  }

  Widget _buildSortModeBanner() {
    return Container(
      key: const ValueKey('sort-mode-banner'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0F4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x55FF6B95), width: 0.8),
      ),
      child: Row(
        children: [
          const Icon(Icons.swap_vert_rounded, size: 18, color: Color(0xFFFF6B95)),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '排序模式：长按卡片拖动调整顺序',
              style: TextStyle(
                color: Color(0xFF8B1A1A),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          FilledButton(
            onPressed: _exitSortMode,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B95),
              minimumSize: const Size(60, 32),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('完成', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';
  }

  // ----- Drag handlers -----
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
      _hoverIndex = index; // start at "leave in place"
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
    // 先清 drag 状态（触发 rebuild：旧顺序 + targetDy=0，卡片平滑归位）
    setState(() {
      _draggingIndex = null;
      _dragCardStartGlobal = null;
      _dragFingerStartGlobal = null;
      _dragFingerCurrentGlobal = null;
      _dragCardSize = null;
      _hoverIndex = null;
    });
    // 再 reorder（触发 rebuild：新顺序，targetDy=0）
    if (draggingIndex != null && hoverIndex != null && draggingIndex != hoverIndex) {
      store.reorderServers(draggingIndex, hoverIndex);
    }
  }

  // ----- Sort-mode entry / exit -----
  void _enterSortMode() {
    setState(() => _isSortMode = true);
  }

  void _exitSortMode() {
    setState(() {
      _isSortMode = false;
      // 防御：如果拖到一半退出，drag 状态一并清掉，避免留下悬浮卡
      _draggingIndex = null;
      _dragCardStartGlobal = null;
      _dragFingerStartGlobal = null;
      _dragFingerCurrentGlobal = null;
      _dragCardSize = null;
      _hoverIndex = null;
    });
  }

  // Walk all card GlobalKeys to find which "slot" the finger is over.
  // A slot is the midpoint of each card. If finger Y < card midY, insert
  // before this card; if >=, tentatively insert after. If we walk past the
  // last card, hoverIndex = N (append to end).
  void _updateHoverIndex() {
    if (_dragFingerCurrentGlobal == null) return;
    final fingerY = _dragFingerCurrentGlobal!.dy;
    final servers = store.orderedServers;
    int newHover = _draggingIndex ?? 0;
    for (int i = 0; i < servers.length; i++) {
      if (i == _draggingIndex) continue; // skip self when iterating
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

  // ----- Visual feedback: floating card -----
  // v2.4.2 砍掉了 drop indicator：v2.4.1 那条粉色线太隐蔽看不出落点。
  // 现在靠 _buildCardSlot 里的 TweenAnimationBuilder 把中间卡整体挤开，
  // "让位置"的动作比一条细线显眼得多。

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
    // Card follows finger by the same delta as the original offset.
    final cardLocalY = (_dragCardStartGlobal!.dy +
            (_dragFingerCurrentGlobal!.dy - _dragFingerStartGlobal!.dy)) -
        stackTopLeft.dy;
    final server = store.orderedServers[_draggingIndex!];
    return Positioned(
      left: cardLocalX,
      top: cardLocalY,
      width: _dragCardSize!.width,
      height: _dragCardSize!.height,
      child: IgnorePointer(
        // Floating preview is purely visual — gestures go to the in-place card.
        child: Transform.scale(
          scale: 1.04,
          alignment: Alignment.topLeft,
          child: Opacity(
            opacity: 0.92,
            child: _ServerCard(
              // No key on the floating one — it lives in a separate subtree.
              server: server,
              store: store,
              isFloating: true,
              isSortMode: false,
              onEnterSortMode: null,
              onDragStart: _noopDragStart,
              onDragUpdate: _noopDragUpdate,
              onDragEnd: _noopDragEnd,
            ),
          ),
        ),
      ),
    );
  }

  // No-op drag callbacks for the floating card preview (it can't initiate
  // a new drag — gestures are captured by IgnorePointer anyway, but these
  // satisfy the required positional parameters).
  void _noopDragStart(Offset _) {}
  void _noopDragUpdate(Offset _) {}
  void _noopDragEnd() {}
}

class _EmptyView extends StatelessWidget {
  final MonitorStore store;
  const _EmptyView({required this.store});
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
                  colors: [Color(0xFFFF6B95), Color(0xFFFFB6C1)],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.dns_rounded, color: Colors.white, size: 32),
            ),
            const SizedBox(height: 16),
            const Text('还没有服务器',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A))),
            const SizedBox(height: 6),
            const Text('点击右上角 + 按钮，添加你的第一台服务器',
                style: TextStyle(color: Color(0xFF7A7A82), fontSize: 13)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => AddServerDialog.show(context, store),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('添加服务器'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B95),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  final MonitorServer server;
  final MonitorStore store;
  // isFloating = true → this card is the preview that follows the finger
  // during a drag. We skip the drag handle, tap, and long-press to keep it
  // purely visual.
  final bool isFloating;
  // isSortMode = true → the whole overview is in "rearrange" mode. The
  // GlassCard's InkWell is disabled and the card is wrapped in a
  // GestureDetector that turns long-press into a drag start.
  final bool isSortMode;
  // Optional callback to enter sort mode from this card's long-press menu.
  // The parent passes null if sort mode shouldn't be offered (e.g. <2
  // servers, or we are already in sort mode).
  final VoidCallback? onEnterSortMode;
  final void Function(Offset fingerGlobal) onDragStart;
  final void Function(Offset fingerGlobal) onDragUpdate;
  final VoidCallback onDragEnd;

  const _ServerCard({
    super.key,
    required this.server,
    required this.store,
    required this.isFloating,
    required this.isSortMode,
    required this.onEnterSortMode,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final agent = store.agentFor(server);
    final hw = agent?.hardware;
    final cpu = hw?.cpu;
    final mem = hw?.memory;
    final gpu = hw?.gpu;
    final disks = hw?.disks ?? const <DiskEntry>[];
    final temp = cpu?.tempC ?? 0;
    final isVps = agent?.isVps ?? false;

    final card = GlassCard(
      onTap: (isSortMode || isFloating) ? null : () => store.selectServer(server),
      onLongPress: (isSortMode || isFloating) ? null : () => _showServerMenu(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isVps ? Icons.public_rounded : Icons.dns_rounded,
                size: 20,
                color: const Color(0xFFFF6B95),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  server.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A)),
                ),
              ),
              StatusBadge(
                agent: agent,
                // v2.4.22: 传 lastSuccessMs 进去让 StatusBadge 算 sa。
                // 之前用 agent.secondsAgo（agent.ts = time.Now()），永远 < 30s，
                // 所以 app 完全连不上 agent 时还显示"在线"。现在用 app 端
                // 上次 poll 成功时间，失败时不更新，自然就显示"卡 Xs/离线"了。
                lastSuccessMs: store.lastSuccessFor(server)?.millisecondsSinceEpoch,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (agent == null) ...[
            Builder(builder: (ctx) {
              final err = store.errorFor(server);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.cloud_off_rounded, size: 14, color: Color(0xFFE53935)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          err ?? '暂无数据（首次拉取中）',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: err != null ? const Color(0xFFE53935) : const Color(0xFF9CA3AF),
                            fontSize: 11,
                            fontFamily: err != null ? 'monospace' : null,
                          ),
                        ),
                      ),
                      _RefreshBtn(onTap: () => store.pollServer(server)),
                    ],
                  ),
                ],
              );
            }),
          ] else if (hw == null) ...[
            const Text('暂无硬件数据', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12)),
          ] else ...[
            Row(
              children: [
                Expanded(child: UsageBar(
                  label: 'CPU',
                  valueText: '${cpu?.percent.toStringAsFixed(1) ?? "0"}%',
                  percent: cpu?.percent ?? 0,
                  icon: Icons.memory_rounded,
                )),
                const SizedBox(width: 12),
                Expanded(child: UsageBar(
                  label: '内存',
                  valueText: mem == null ? '—' : '${mem.percent.toStringAsFixed(0)}%',
                  percent: mem?.percent ?? 0,
                  icon: Icons.storage_rounded,
                )),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _MiniStat(icon: Icons.thermostat_rounded, label: '温度', value: temp > 0 ? '${temp.toStringAsFixed(0)}°C' : '—', color: tempColor(temp)),
                if (gpu != null && gpu.hasUtil)
                  _MiniStat(icon: Icons.developer_board_rounded, label: 'GPU', value: '${gpu.percent!.toStringAsFixed(0)}%', color: usageColor(gpu.percent!)),
                if (gpu != null && gpu.hasTemp)
                  _MiniStat(icon: Icons.thermostat_rounded, label: '显卡', value: '${gpu.tempC!.toStringAsFixed(0)}°C', color: tempColor(gpu.tempC!)),
                if (disks.isNotEmpty)
                  _MiniStat(icon: Icons.save_rounded, label: '磁盘', value: '${disks.first.percent.toStringAsFixed(0)}%', color: usageColor(disks.first.percent)),
                if (agent.hasXui)
                  _MiniStat(icon: Icons.people_alt_rounded, label: '客户端', value: '${agent.xui!.onlineCount}/${agent.xui!.totalClients}', color: const Color(0xFFFF6B95)),
              ],
            ),
          ],
        ],
      ),
    );

    // v2.4.1 重做：抛弃拖手柄。改成 iOS 主屏编辑风格——
    // 用户先进 sort mode（菜单 → 排序），所有卡晃动，长按整张卡 = 拖动。
    // 退出点顶部"完成"banner。
    if (isFloating) return card;
    if (isSortMode) {
      return GestureDetector(
        // 长按 500ms 后触发拖动（iOS 风格），后续手指移动用 onLongPressMoveUpdate 跟手。
        // GlassCard 在 sort mode 下禁用 onTap / onLongPress，所以这里没有手势冲突。
        onLongPressStart: (d) => onDragStart(d.globalPosition),
        onLongPressMoveUpdate: (d) => onDragUpdate(d.globalPosition),
        onLongPressEnd: (_) => onDragEnd(),
        child: card,
      );
    }
    return card;
  }

  void _showServerMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ServerMenu(
        store: store,
        server: server,
        onEnterSortMode: onEnterSortMode,
      ),
    );
  }
}

// v2.4.1 iOS 风格晃动动画：sort mode 下非正在拖的卡片轻微左右摆动。
// 用 AnimationController.repeat(reverse:true) + sin 波驱动 Transform.rotate，
// 振幅 ~0.7° 看起来"心虚的动"而不是"卖力的抖"。
class _ShakeAnimation extends StatefulWidget {
  final Widget child;
  final bool enabled;
  const _ShakeAnimation({required this.child, required this.enabled});

  @override
  State<_ShakeAnimation> createState() => _ShakeAnimationState();
}

class _ShakeAnimationState extends State<_ShakeAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  // 给每张卡一个轻微不同的相位，看起来更自然
  late final double _phaseOffset;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    // 用 widget 自身 hashCode 当相位种子，让每张卡的抖动看起来错开，更自然
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
        final angle =
            math.sin((_ctrl.value * 2 * math.pi) + _phaseOffset) * 0.012;
        return Transform.rotate(angle: angle, child: child);
      },
      child: widget.child,
    );
  }
}

class _ServerMenu extends StatelessWidget {
  final MonitorStore store;
  final MonitorServer server;
  // Optional callback to enter sort mode. The parent passes null when sort
  // mode isn't available (e.g. <2 servers) and the entry is hidden.
  final VoidCallback? onEnterSortMode;
  const _ServerMenu({
    required this.store,
    required this.server,
    this.onEnterSortMode,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xF2FFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFB6C1), width: 0.6),
        boxShadow: const [
          BoxShadow(color: Color(0x33FF6B95), blurRadius: 18, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36, height: 4,
            margin: const EdgeInsets.only(top: 6, bottom: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFE5E5EA),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 排序入口：iOS 主屏编辑模式那种。点完进入 sort mode（卡片晃动 + 长按=拖动）
          if (onEnterSortMode != null)
            ListTile(
              leading: const Icon(Icons.swap_vert_rounded, color: Color(0xFFFF6B95)),
              title: const Text('排序'),
              subtitle: const Text('卡片晃动后，长按拖动调整顺序',
                  style: TextStyle(fontSize: 11, color: Color(0xFF7A7A82))),
              onTap: () {
                Navigator.pop(context);
                onEnterSortMode!();
              },
            ),
          ListTile(
            leading: const Icon(Icons.open_in_new_rounded, color: Color(0xFFFF6B95)),
            title: const Text('查看详情'),
            onTap: () {
              Navigator.pop(context);
              store.selectServer(server);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_rounded, color: Color(0xFFFF6B95)),
            title: const Text('编辑'),
            subtitle: const Text('改名字 / 域名 / 端口 / Token',
                style: TextStyle(fontSize: 11, color: Color(0xFF7A7A82))),
            onTap: () {
              Navigator.pop(context);
              AddServerDialog.show(context, store, initial: server);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: Color(0xFFE53935)),
            title: const Text('删除服务器', style: TextStyle(color: Color(0xFFE53935))),
            onTap: () async {
              Navigator.pop(context);
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFFFFFFFF),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: const Text('删除服务器'),
                  content: Text('确认删除「${server.name}」？\n仅从本应用移除，后端数据会保留。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await store.deleteServer(server.id);
              }
            },
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;
  const _MiniStat({required this.icon, required this.label, required this.value, this.color});
  @override
  Widget build(BuildContext context) {
    final c = color ?? const Color(0xFF7A7A82);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 3),
        Text('$label $value', style: const TextStyle(fontSize: 12, color: Color(0xFF2C2C2C))),
      ],
    );
  }
}

class StatusBadge extends StatelessWidget {
  final AgentData? agent;
  final int? lastSuccessMs; // v2.4.22: 用 store 的 lastSuccessMs 算 secondsAgo（不再用 agent.ts）
  const StatusBadge({super.key, required this.agent, this.lastSuccessMs});
  @override
  Widget build(BuildContext context) {
    String label;
    Color color;
    // v2.4.22: 用 lastSuccessMs 算 secondsAgo（app 上次成功 poll 距今多久）。
    // 之前用 agent.secondsAgo（基于 agent 返回的 timestamp = time.Now().Unix()，
    // 跟数据实际新鲜度无关，永远 < 30 秒，所以 server 断联几小时都显示"在线"）。
    // 现在用 store 里的 lastSuccessMs：app poll 成功时更新，失败时不变，
    // 自然会"卡 X 秒" / "离线"，跟 app 端实际连接状态一致。
    int sa;
    if (lastSuccessMs == null || lastSuccessMs == 0) {
      sa = -1;
    } else {
      sa = ((DateTime.now().millisecondsSinceEpoch - lastSuccessMs!) / 1000).round();
    }
    if (lastSuccessMs == null || lastSuccessMs == 0) {
      label = '加载中';
      color = const Color(0xFF9CA3AF);
    } else if (sa < 30) {
      label = '在线';
      color = const Color(0xFF10B981);
    } else if (sa < 300) {
      label = '卡 ${sa}s';
      color = const Color(0xFFF59E0B);
    } else {
      label = '离线';
      color = const Color(0xFFE53935);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

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
            const Icon(Icons.error_outline_rounded, color: Color(0xFFE53935), size: 56),
            const SizedBox(height: 12),
            const Text('连不上后端', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A))),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF7A7A82), fontSize: 12)),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _RefreshBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _RefreshBtn({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFFE4EC),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.refresh_rounded, size: 13, color: Color(0xFFFF6B95)),
            SizedBox(width: 4),
            Text('重试', style: TextStyle(color: Color(0xFFFF6B95), fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
