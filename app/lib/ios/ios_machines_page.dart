// iOS 风格机器列表页
//
// - 大标题（iOS 11+ large title 风格）
// - 服务器卡片：液态玻璃 + mini stat 行
// - 点击进 detail（push 动画）

import 'package:flutter/cupertino.dart';
import '../models.dart';
import '../store.dart';
import 'ios_theme.dart';
import 'ios_glass.dart';

class IOSMachinesPage extends StatefulWidget {
  final MonitorStore store;
  const IOSMachinesPage({super.key, required this.store});

  @override
  State<IOSMachinesPage> createState() => _IOSMachinesPageState();
}

class _IOSMachinesPageState extends State<IOSMachinesPage> {
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final servers = widget.store.servers;
    final data = widget.store.data;

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        // 大标题（iOS 11+ 风格，滚动时缩小成小标题）
        CupertinoSliverNavigationBar(
          largeTitle: const Text('机器'),
          backgroundColor: IOSTheme.glassDark,
          border: null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CupertinoButton(
                padding: EdgeInsets.zero,
                child: const Icon(CupertinoIcons.refresh, color: IOSTheme.primary, size: 22),
                onPressed: widget.store.refresh,
              ),
              CupertinoButton(
                padding: EdgeInsets.zero,
                child: const Icon(CupertinoIcons.add, color: IOSTheme.primary, size: 22),
                onPressed: () => Navigator.of(context).pushNamed('/add'),
              ),
            ],
          ),
        ),
        if (servers.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.desktopcomputer, size: 64, color: IOSTheme.textTertiary),
                  SizedBox(height: 16),
                  Text('还没有机器', style: TextStyle(color: IOSTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.w600)),
                  SizedBox(height: 8),
                  Text('点右上角 + 添加', style: TextStyle(color: IOSTheme.textTertiary, fontSize: 14)),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              IOSTheme.paddingL, IOSTheme.paddingS,
              IOSTheme.paddingL, 100,  // 底部留 tab bar 空间
            ),
            sliver: SliverList.separated(
              itemCount: servers.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (ctx, i) {
                final s = servers[i];
                final d = data[s.id];
                return _ServerCard(server: s, data: d, onTap: () {
                  Navigator.of(context).pushNamed('/detail', arguments: s);
                });
              },
            ),
          ),
      ],
    );
  }
}

class _ServerCard extends StatelessWidget {
  final MonitorServer server;
  final AgentData? data;
  final VoidCallback onTap;
  const _ServerCard({required this.server, required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = data;
    final hw = d?.hardware;
    final cpu = hw?.cpu;
    final mem = hw?.memory;
    final disk = hw?.disk;
    final xui = d?.xui;
    final online = d != null && d.secondsAgo * 1000 < 120000;
    final cpuPct = cpu?.percent;
    final memPct = mem?.percent;
    final diskPct = disk?.percent;

    final statusColor = onlineStatusColor(online, d?.timestamp != null ? d!.timestamp * 1000 : 0);

    return GlassContainer(
      onTap: onTap,
      padding: const EdgeInsets.all(IOSTheme.paddingL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部：名字 + 状态
          Row(
            children: [
              StatusDot(color: statusColor),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.name,
                      style: const TextStyle(
                        color: IOSTheme.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.3,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (d != null)
                      Text(
                        '${_statusText(online, d.timestamp * 1000)} · ${_timeAgo(d.timestamp * 1000)}',
                        style: const TextStyle(
                          color: IOSTheme.textTertiary,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              if (xui != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: IOSTheme.primary.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '3xui ${xui.onlineCount}/${xui.totalClients}',
                    style: const TextStyle(
                      color: IOSTheme.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          // mini stats
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'CPU',
                  value: _fmtPercent(cpuPct),
                  valueColor: cpuPct != null ? _percentColor(cpuPct) : null,
                ),
              ),
              const SizedBox(width: 8),
              Container(width: 1, height: 32, color: IOSTheme.glassBorder),
              const SizedBox(width: 8),
              Expanded(
                child: StatTile(
                  label: '内存',
                  value: _fmtPercent(memPct),
                  valueColor: memPct != null ? _percentColor(memPct) : null,
                ),
              ),
              const SizedBox(width: 8),
              Container(width: 1, height: 32, color: IOSTheme.glassBorder),
              const SizedBox(width: 8),
              Expanded(
                child: StatTile(
                  label: '磁盘',
                  value: _fmtPercent(diskPct),
                  valueColor: diskPct != null ? _percentColor(diskPct) : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _fmtPercent(double? pct) => pct != null ? '${pct.toStringAsFixed(0)}%' : '—';

  String _statusText(bool online, int lastReceivedMs) {
    if (lastReceivedMs == 0) return '从未上报';
    if (online) return '在线';
    final age = DateTime.now().millisecondsSinceEpoch - lastReceivedMs;
    if (age < 300 * 1000) return '卡';
    return '离线';
  }

  String _timeAgo(int lastReceivedMs) {
    if (lastReceivedMs == 0) return '';
    final age = DateTime.now().millisecondsSinceEpoch - lastReceivedMs;
    if (age < 60 * 1000) return '${age ~/ 1000}秒前';
    if (age < 3600 * 1000) return '${age ~/ 60000}分钟前';
    if (age < 86400 * 1000) return '${age ~/ 3600000}小时前';
    return '${age ~/ 86400000}天前';
  }

  Color? _percentColor(double pct) {
    if (pct < 60) return IOSTheme.success;
    if (pct < 85) return IOSTheme.warning;
    return IOSTheme.danger;
  }
}
