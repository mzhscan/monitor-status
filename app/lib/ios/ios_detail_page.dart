// iOS 风格机器详情页
//
// - push 进来（从右往左）
// - 大标题（机器名）
// - iOS 27 风格资源条（gradient + glass）
// - 3xui 客户端列表（玻璃卡片）
// - 系统服务列表

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models.dart';
import '../store.dart';
import '../widgets.dart' show formatBytes;
import 'ios_theme.dart';
import 'ios_glass.dart';

class IOSDetailPage extends StatefulWidget {
  final MonitorStore store;
  final MonitorServer server;
  const IOSDetailPage({super.key, required this.store, required this.server});

  @override
  State<IOSDetailPage> createState() => _IOSDetailPageState();
}

class _IOSDetailPageState extends State<IOSDetailPage> {
  AgentData? _data;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onChange);
    _refresh();
  }

  @override
  void dispose() {
    widget.store.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {
      _data = widget.store.data[widget.server.id];
      _error = widget.store.error;
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.store.refresh();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return CupertinoPageScaffold(
      backgroundColor: Colors.transparent,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: IOSTheme.glassDark,
        border: null,
        middle: Text(widget.server.name),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _refresh,
          child: const Icon(CupertinoIcons.refresh, color: IOSTheme.primary),
        ),
      ),
      child: SafeArea(
        child: _loading && d == null
            ? const Center(child: CupertinoActivityIndicator(radius: 14))
            : _error != null && d == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, style: const TextStyle(color: IOSTheme.danger)),
                    ),
                  )
                : _buildContent(d!),
      ),
    );
  }

  Widget _buildContent(AgentData d) {
    final hw = d.hardware;
    final cpu = hw?.cpu;
    final mem = hw?.memory;
    final load = hw?.load;
    final net = hw?.network;
    final disks = hw?.disks ?? const <DiskEntry>[];
    final xui = d.xui;
    final services = d.services;
    // iOS 卡片显示 120s 内为"在线"（比 Android 30s 阈值宽松一点）
    final online = d.secondsAgo * 1000 < 120000;

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        CupertinoSliverRefreshControl(onRefresh: _refresh),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            IOSTheme.paddingL, IOSTheme.paddingM,
            IOSTheme.paddingL, 100,
          ),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              // 状态条
              _statusBar(d, online),
              const SizedBox(height: IOSTheme.paddingL),
              // 资源占用
              _resourceSection(cpu, mem, load, net, disks, d),
              if (services.isNotEmpty) ...[
                const SizedBox(height: IOSTheme.paddingL),
                _servicesSection(services),
              ],
              if (xui != null && xui.clients.isNotEmpty) ...[
                const SizedBox(height: IOSTheme.paddingL),
                _xuiSection(xui),
              ],
            ]),
          ),
        ),
      ],
    );
  }

  Widget _statusBar(AgentData d, bool online) {
    final color = onlineStatusColor(online, d.timestamp * 1000);
    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: IOSTheme.paddingL, vertical: IOSTheme.paddingM),
      child: Row(
        children: [
          StatusDot(color: color, size: 12),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  online ? '在线' : (d.timestamp == 0 ? '未配置' : '离线'),
                  style: const TextStyle(
                    color: IOSTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  d.timestamp == 0
                      ? ''
                      : '${_timeAgo(d.timestamp * 1000)} · 数据于 ${_time(d.timestamp * 1000)}',
                  style: const TextStyle(color: IOSTheme.textTertiary, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _resourceSection(
    CpuInfo? cpu,
    MemoryInfo? mem,
    LoadInfo? load,
    NetworkInfo? net,
    List<DiskEntry> disks,
    AgentData d,
  ) {
    Widget bar(String label, double? pct, String? hint) {
      if (pct == null) return const SizedBox.shrink();
      final color = pct < 60 ? IOSTheme.success : (pct < 85 ? IOSTheme.warning : IOSTheme.danger);
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
                Text('${pct.toStringAsFixed(1)}%', style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 6),
            // 资源条：iOS 27 风格（gradient + rounded）
            Container(
              height: 6,
              decoration: BoxDecoration(
                color: IOSTheme.glassLight,
                borderRadius: BorderRadius.circular(3),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: (pct / 100).clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [color, color.withOpacity(0.7)]),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(hint, style: const TextStyle(color: IOSTheme.textTertiary, fontSize: 11)),
            ],
          ],
        ),
      );
    }

    return GlassContainer(
      padding: const EdgeInsets.all(IOSTheme.paddingL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('资源占用', style: TextStyle(color: IOSTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
          const SizedBox(height: 14),
          bar('CPU', cpu?.percent, cpu?.model.isNotEmpty == true ? cpu!.model : null),
          bar('内存', mem?.percent,
              mem != null ? '${mem.usedGb.toStringAsFixed(1)} / ${mem.totalGb.toStringAsFixed(1)} GB' : null),
          if (disks.isNotEmpty)
            bar('磁盘', disks.first.percent,
                '${disks.first.usedGb.toStringAsFixed(1)} / ${disks.first.totalGb.toStringAsFixed(0)} GB'),
          const SizedBox(height: 14),
          // 小卡片：load / uptime / network
          Row(
            children: [
              Expanded(child: _miniKV('Load 1m', load?.l1.toStringAsFixed(2) ?? '—')),
              Expanded(child: _miniKV('Load 5m', load?.l5.toStringAsFixed(2) ?? '—')),
              Expanded(child: _miniKV('Load 15m', load?.l15.toStringAsFixed(2) ?? '—')),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _miniKV('运行时长', d.hardware?.uptime ?? '—')),
              Expanded(child: _miniKV('接收', formatBytes(net?.rxBytes ?? 0))),
              Expanded(child: _miniKV('发送', formatBytes(net?.txBytes ?? 0))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniKV(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: IOSTheme.textTertiary, fontSize: 10)),
          Text(value, style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _servicesSection(List<ServiceEntry> services) {
    return GlassContainer(
      padding: const EdgeInsets.all(IOSTheme.paddingL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('系统服务', style: TextStyle(color: IOSTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
          const SizedBox(height: 12),
          ...services.map((s) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                StatusDot(color: statusColor(s.status), size: 6),
                const SizedBox(width: 8),
                Expanded(child: Text(s.name, style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 14))),
                Text(s.status, style: TextStyle(
                  color: statusColor(s.status),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                )),
              ],
            ),
          )),
        ],
      ),
    );
  }

  Widget _xuiSection(XuiInfo xui) {
    final clients = xui.clients;
    final totalUp = clients.fold<int>(0, (s, c) => s + c.upBytes);
    final totalDn = clients.fold<int>(0, (s, c) => s + c.downBytes);
    final inbound = xui.inboundTotal;

    return GlassContainer(
      padding: const EdgeInsets.all(IOSTheme.paddingL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('3xui', style: TextStyle(color: IOSTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _miniKV('在线', '${xui.onlineCount}')),
              Expanded(child: _miniKV('总客户端', '${xui.totalClients}')),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _miniKV('总上行', formatBytes(totalUp))),
              Expanded(child: _miniKV('总下行', formatBytes(totalDn))),
            ],
          ),
          if (inbound != null) ...[
            const SizedBox(height: 14),
            Container(height: 1, color: IOSTheme.glassBorder),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: _miniKV('主机上行 (实时)', formatBytes(inbound.upBytes))),
                Expanded(child: _miniKV('主机下行 (实时)', formatBytes(inbound.downBytes))),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'inbound 实时流量（per-client 数字断开时才更新，滞后 20+ 分钟）',
              style: TextStyle(color: IOSTheme.textTertiary, fontSize: 11),
            ),
          ],
          const SizedBox(height: 14),
          const Text('客户端', style: TextStyle(color: IOSTheme.textTertiary, fontSize: 12)),
          const SizedBox(height: 6),
          ...clients.map((c) => Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: IOSTheme.glassDark,
              borderRadius: BorderRadius.circular(IOSTheme.radiusS),
            ),
            child: Row(
              children: [
                StatusDot(color: c.online ? IOSTheme.success : IOSTheme.textTertiary, size: 6),
                const SizedBox(width: 6),
                Expanded(child: Text(c.email, style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 13), overflow: TextOverflow.ellipsis)),
                Text(
                  c.enable ? (c.online ? '在线' : '启用') : '停用',
                  style: TextStyle(color: c.online ? IOSTheme.success : IOSTheme.textTertiary, fontSize: 11),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }

  String _time(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
  }

  String _timeAgo(int lastReceivedMs) {
    if (lastReceivedMs == 0) return '';
    final age = DateTime.now().millisecondsSinceEpoch - lastReceivedMs;
    if (age < 60 * 1000) return '${age ~/ 1000}秒前';
    if (age < 3600 * 1000) return '${age ~/ 60000}分钟前';
    if (age < 86400 * 1000) return '${age ~/ 3600000}小时前';
    return '${age ~/ 86400000}天前';
  }
}
