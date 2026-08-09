// Overview page: one glass card per registered server, plus a "add another"
// hint if the list is empty. Tapping a card navigates to that server's
// detail page. Long-pressing a card opens a context menu. Dragging the
// right-side drag handle reorders the list (hand-rolled in v2.4.0 to
// avoid the ReorderableListView gray-area bug).

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
  // floating preview + drop indicator can be positioned via the Stack's
  // RenderBox regardless of how the ListView scrolls.
  int? _draggingIndex;
  Offset? _dragCardStartGlobal; // top-left of the source card at drag start
  Offset? _dragFingerStartGlobal; // finger position at drag start
  Offset? _dragFingerCurrentGlobal; // current finger position (updated on move)
  Size? _dragCardSize; // size of the source card
  int? _hoverIndex; // "insert before this index" — equals N means "append"
  double? _hoverLineGlobalY; // global Y of the drop indicator line

  // GlobalKey per card (keyed by stable server.id) so we can look up each
  // card's RenderBox during a drag to compute hover position.
  final Map<String, GlobalKey> _cardKeys = {};
  // GlobalKey on the Stack (so we can convert screen-global <-> Stack-local
  // coordinates for the floating card and drop indicator).
  final GlobalKey _stackKey = GlobalKey();

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
        // Drop indicator line (rendered between cards based on _hoverIndex)
        if (_hoverLineGlobalY != null) _buildDropIndicator(),
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
          if (store.error != null)
            Container(
              key: const ValueKey('error-banner'),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0x1AE53935),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x55E53935)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Color(0xFFE53935), size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text('拉取失败：${store.error}', style: const TextStyle(color: Color(0xFF8B1A1A), fontSize: 12))),
                ],
              ),
            ),
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
    return Padding(
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
          onDragStart: (fingerGlobal) => _onCardDragStart(i, fingerGlobal),
          onDragUpdate: _onCardDragUpdate,
          onDragEnd: _onCardDragEnd,
        ),
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
      _updateHoverLine();
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
    if (_draggingIndex != null && _hoverIndex != null && _draggingIndex != _hoverIndex) {
      store.reorderServers(_draggingIndex!, _hoverIndex!);
    }
    setState(() {
      _draggingIndex = null;
      _dragCardStartGlobal = null;
      _dragFingerStartGlobal = null;
      _dragFingerCurrentGlobal = null;
      _dragCardSize = null;
      _hoverIndex = null;
      _hoverLineGlobalY = null;
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
    _updateHoverLine();
  }

  // Compute the Y position of the drop indicator line based on _hoverIndex.
  // If hoverIndex < N, line goes at the top of that card. If hoverIndex == N,
  // line goes at the bottom of the last card.
  void _updateHoverLine() {
    if (_hoverIndex == null) {
      _hoverLineGlobalY = null;
      return;
    }
    final servers = store.orderedServers;
    if (servers.isEmpty) {
      _hoverLineGlobalY = null;
      return;
    }
    if (_hoverIndex! >= servers.length) {
      // Insert at the end — use last card's bottom
      final lastKey = _cardKeys[servers.last.id];
      final ctx = lastKey?.currentContext;
      if (ctx == null) { _hoverLineGlobalY = null; return; }
      final rb = ctx.findRenderObject() as RenderBox?;
      if (rb == null || !rb.attached) { _hoverLineGlobalY = null; return; }
      _hoverLineGlobalY = rb.localToGlobal(Offset.zero).dy + rb.size.height;
    } else {
      // Insert before card at hoverIndex — use that card's top
      final key = _cardKeys[servers[_hoverIndex!].id];
      final ctx = key?.currentContext;
      if (ctx == null) { _hoverLineGlobalY = null; return; }
      final rb = ctx.findRenderObject() as RenderBox?;
      if (rb == null || !rb.attached) { _hoverLineGlobalY = null; return; }
      _hoverLineGlobalY = rb.localToGlobal(Offset.zero).dy;
    }
  }

  // ----- Visual feedback: drop indicator + floating card -----
  Widget _buildDropIndicator() {
    final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null || _hoverLineGlobalY == null) return const SizedBox.shrink();
    final stackTopLeft = stackBox.localToGlobal(Offset.zero);
    final localY = _hoverLineGlobalY! - stackTopLeft.dy;
    return Positioned(
      left: 12,
      right: 12,
      top: localY - 2, // 4px line, centered on localY
      child: IgnorePointer(
        child: Container(
          height: 4,
          decoration: BoxDecoration(
            color: const Color(0xFFFF6B95),
            borderRadius: BorderRadius.circular(2),
            boxShadow: [
              BoxShadow(color: const Color(0xFFFF6B95).withOpacity(0.4), blurRadius: 8),
            ],
          ),
        ),
      ),
    );
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
  final void Function(Offset fingerGlobal) onDragStart;
  final void Function(Offset fingerGlobal) onDragUpdate;
  final VoidCallback onDragEnd;

  const _ServerCard({
    super.key,
    required this.server,
    required this.store,
    required this.isFloating,
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

    return GlassCard(
      onTap: isFloating ? null : () => store.selectServer(server),
      onLongPress: isFloating ? null : () => _showServerMenu(context),
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
              StatusBadge(agent: agent),
              if (!isFloating) ...[
                const SizedBox(width: 4),
                // Drag handle: immediate drag on touch (matches the old
                // ReorderableDragStartListener feel). Long-press on the
                // card body still opens the menu — no conflict.
                _DragHandle(
                  onDragStart: onDragStart,
                  onDragUpdate: onDragUpdate,
                  onDragEnd: onDragEnd,
                ),
              ],
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
  }

  void _showServerMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ServerMenu(store: store, server: server),
    );
  }
}

// Tiny widget so the GestureDetector wrapping the drag-handle icon doesn't
// have to fight with the GlassCard's InkWell for pointer events.
class _DragHandle extends StatelessWidget {
  final void Function(Offset fingerGlobal) onDragStart;
  final void Function(Offset fingerGlobal) onDragUpdate;
  final VoidCallback onDragEnd;
  const _DragHandle({
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (d) => onDragStart(d.globalPosition),
      onPanUpdate: (d) => onDragUpdate(d.globalPosition),
      onPanEnd: (_) => onDragEnd(),
      child: const Padding(
        padding: EdgeInsets.all(4),
        child: Icon(Icons.drag_indicator_rounded, size: 20, color: Color(0xFFB5B5BD)),
      ),
    );
  }
}

class _ServerMenu extends StatelessWidget {
  final MonitorStore store;
  final MonitorServer server;
  const _ServerMenu({required this.store, required this.server});
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
  const StatusBadge({super.key, required this.agent});
  @override
  Widget build(BuildContext context) {
    String label;
    Color color;
    final sa = agent?.secondsAgo ?? -1;
    if (agent?.isLive == true) {
      label = '在线';
      color = const Color(0xFF10B981);
    } else if (sa >= 0 && sa < 300) {
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
