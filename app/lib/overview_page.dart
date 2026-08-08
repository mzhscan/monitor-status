// Overview page: one glass card per registered server, plus a "add another"
// hint if the list is empty. Tapping a card navigates to that server's
// detail page.

import 'package:flutter/material.dart';
import 'add_server_dialog.dart';
import 'models.dart';
import 'store.dart';
import 'widgets.dart';

class OverviewPage extends StatelessWidget {
  final MonitorStore store;
  const OverviewPage({super.key, required this.store});

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

    return RefreshIndicator(
      color: const Color(0xFFFF6B95),
      backgroundColor: Colors.white,
      onRefresh: () async => Future.delayed(const Duration(milliseconds: 500)),
      // 唯一改动：SliverReorderableList 在 v2.2.0 视觉坏（拖手柄列被拉成卡片全高），
      // 换成普通 ReorderableListView。其它逻辑 / 卡片结构 / 长按=菜单 / 拖手柄在右
      // 全部保持 v2.2.0 原样。
      child: ReorderableListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        buildDefaultDragHandles: false,
        onReorder: (oldIndex, newIndex) {
          store.reorderServers(oldIndex, newIndex);
        },
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
            Padding(
              key: ValueKey(store.orderedServers[i].id),
              padding: const EdgeInsets.only(bottom: 10),
              child: _ServerCard(server: store.orderedServers[i], store: store, index: i),
            ),
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

  static String _fmtTime(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';
  }
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
  final int index;
  const _ServerCard({required this.server, required this.store, required this.index});

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

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: GlassCard(
            onTap: () => store.selectServer(server),
            onLongPress: () => _showServerMenu(context),
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
          ),
        ),
        // 拖动手柄：长按这个才能拖动排序
        ReorderableDragStartListener(
          index: index,
          child: Container(
            width: 36,
            margin: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F7FA),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E5EA), width: 0.6),
            ),
            child: const Center(
              child: Icon(Icons.drag_indicator_rounded, size: 22, color: Color(0xFFB5B5BD)),
            ),
          ),
        ),
      ],
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
