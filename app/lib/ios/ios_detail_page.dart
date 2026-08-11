// iOS 风格机器详情页
//
// 跟安卓 dynamic_server_page.dart 对齐：
//   - 头部：服务器名 + NAS/VPS chip + 状态徽章（用 lastSuccessMs，跟安卓一致）
//   - 资源占用（CPU/内存/磁盘/load/network）
//   - 系统服务列表
//   - 3xui 客户端列表
//   - 错误整页 + 重试
//   - 底部"更新于"时间戳
//
// 视觉保持 iOS 27 Liquid Glass。

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;
import '../models.dart';
import '../store.dart';
import '../widgets.dart' show formatBytes;
import 'ios_helpers.dart';
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

  Future<void> _edit() async {
    await Navigator.of(context).pushNamed('/add', arguments: widget.server);
  }

  Future<void> _retry() async {
    await widget.store.pollServer(widget.server);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.store.data[widget.server.id];
    final error = widget.store.errorFor(widget.server);
    final lastSuccessMs = widget.store.lastSuccessFor(widget.server)?.millisecondsSinceEpoch;
    final status = computeStatus(lastSuccessMs);

    return CupertinoPageScaffold(
      backgroundColor: Colors.transparent,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: IOSTheme.glassDark,
        border: null,
        middle: Text(widget.server.name),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.store.isLoading)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: CupertinoActivityIndicator(radius: 9),
              ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: _retry,
              child: const Icon(CupertinoIcons.refresh, color: IOSTheme.primary),
            ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: _edit,
              child: const Icon(CupertinoIcons.pencil, color: IOSTheme.primary),
            ),
          ],
        ),
      ),
      child: SafeArea(
        child: data == null
            ? (error != null && error.isNotEmpty
                ? _ErrorView(message: error, onRetry: _retry)
                : const Center(child: CupertinoActivityIndicator(radius: 14)))
            : _buildContent(data, status),
      ),
    );
  }

  Widget _buildContent(AgentData d, ServerStatus status) {
    final hw = d.hardware;
    final cpu = hw?.cpu;
    final mem = hw?.memory;
    final load = hw?.load;
    final net = hw?.network;
    final disks = hw?.disks ?? const <DiskEntry>[];
    final xui = d.xui;
    final services = d.services;
    final isVps = d.kind == 'vps' || d.xui != null;

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        CupertinoSliverRefreshControl(onRefresh: _retry),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            IOSTheme.paddingL, IOSTheme.paddingM,
            IOSTheme.paddingL, 140,  // 留出浮动 tab bar 空间
          ),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _header(d, status, isVps),
              const SizedBox(height: IOSTheme.paddingL),
              _resourceSection(cpu, mem, load, net, disks, d),
              if (disks.isNotEmpty) ...[
                const SizedBox(height: IOSTheme.paddingL),
                _disksSection(disks),
              ],
              if (services.isNotEmpty) ...[
                const SizedBox(height: IOSTheme.paddingL),
                _servicesSection(services),
              ],
              if (xui != null && xui.clients.isNotEmpty) ...[
                const SizedBox(height: IOSTheme.paddingL),
                _xuiSection(xui),
              ],
              // 底部"更新于"时间戳（跟安卓 detail 页一致）
              if (widget.store.lastSuccessAt != null) ...[
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    '更新于 ${fmtTime(widget.store.lastSuccessAt!)}',
                    style: const TextStyle(
                      color: IOSTheme.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ]),
          ),
        ),
      ],
    );
  }

  Widget _header(AgentData d, ServerStatus status, bool isVps) {
    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: IOSTheme.paddingL, vertical: IOSTheme.paddingM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [IOSTheme.primary, IOSTheme.primaryLight],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isVps ? CupertinoIcons.globe : CupertinoIcons.desktopcomputer,
                  color: CupertinoColors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: IOSTheme.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isVps ? 'VPS 主机' : 'NAS / 主机',
                      style: const TextStyle(color: IOSTheme.textTertiary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              StatusPill(status: status),
            ],
          ),
          const SizedBox(height: 12),
          // NAS/VPS chip + agent/SSH chip + 运行时长
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _chip(
                icon: isVps ? CupertinoIcons.cloud : CupertinoIcons.archivebox,
                text: isVps ? 'VPS' : 'NAS',
                color: isVps ? IOSTheme.info : IOSTheme.success,
              ),
              _chip(
                icon: CupertinoIcons.bolt,
                text: 'Agent',
                color: IOSTheme.primary,
              ),
              if ((d.hardware?.uptime ?? '').isNotEmpty)
                _chip(
                  icon: CupertinoIcons.time,
                  text: d.hardware!.uptime,
                  color: IOSTheme.success,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip({required IconData icon, required String text, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
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

  // 硬盘 section（多盘 + alias/隐藏编辑，跟安卓 _DisksCard 行为对齐）
  Widget _disksSection(List<DiskEntry> disks) {
    final hidden = widget.server.hiddenDisks;
    final aliases = widget.server.diskAliases;
    final visible = disks.where((d) => hidden[d.mount] != true).toList();
    final hiddenCount = disks.length - visible.length;
    return GlassContainer(
      padding: const EdgeInsets.all(IOSTheme.paddingL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('硬盘', style: TextStyle(color: IOSTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
              const Spacer(),
              Text(
                hiddenCount > 0
                    ? '${visible.length} 块 / 已隐藏 $hiddenCount'
                    : '${visible.length} 块',
                style: const TextStyle(fontSize: 11, color: IOSTheme.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '所有硬盘都已隐藏，去"编辑"恢复',
                style: TextStyle(color: IOSTheme.textTertiary, fontSize: 12),
              ),
            )
          else
            for (var i = 0; i < visible.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _DiskRow(
                disk: visible[i],
                alias: aliases[visible[i].mount],
                onTap: () => _editDisk(visible[i]),
              ),
            ],
        ],
      ),
    );
  }

  void _editDisk(DiskEntry d) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => _EditDiskSheet(
        serverId: widget.server.id,
        disk: d,
        currentAlias: widget.server.diskAliases[d.mount],
        isHidden: widget.server.hiddenDisks[d.mount] == true,
        store: widget.store,
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
                StatusDot(color: _serviceColor(s.status), size: 6),
                const SizedBox(width: 8),
                Expanded(child: Text(s.name, style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 14))),
                Text(_translateStatus(s.status), style: TextStyle(
                  color: _serviceColor(s.status),
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

  // 把 systemd 状态翻译成中文（跟安卓 translateStatus 对齐）
  String _translateStatus(String s) {
    switch (s) {
      case 'active': return '运行中';
      case 'inactive': return '未运行';
      case 'failed': return '已失败';
      case 'activating': return '启动中';
      case 'deactivating': return '停止中';
      case 'reloading': return '重载中';
      case 'maintenance': return '维护中';
      default: return s.isEmpty ? '未知' : s;
    }
  }

  Color _serviceColor(String status) {
    switch (status) {
      case 'active': return IOSTheme.success;
      case 'failed': return IOSTheme.danger;
      case 'inactive': return IOSTheme.danger;
      default: return IOSTheme.textTertiary;
    }
  }
}

// 错误整页（跟安卓 detail 页错误态对齐）
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
// Disk row（iOS 27 风格：玻璃条 + 温度 + 使用率 + 编辑入口）
// 跟安卓 _DiskRow 行为对齐
// ============================================================
class _DiskRow extends StatelessWidget {
  final DiskEntry disk;
  final String? alias;
  final VoidCallback? onTap;
  const _DiskRow({required this.disk, this.alias, this.onTap});
  @override
  Widget build(BuildContext context) {
    final mountLeaf = disk.mount == '/' ? '系统盘' : disk.mount.split('/').last;
    final displayName = (alias != null && alias!.isNotEmpty)
        ? alias!
        : (disk.name.isNotEmpty
            ? disk.name
            : (mountLeaf.isNotEmpty ? mountLeaf : disk.device));
    final color = disk.percent < 60
        ? IOSTheme.success
        : (disk.percent < 85 ? IOSTheme.warning : IOSTheme.danger);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    displayName.isEmpty ? '(未挂载)' : displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: IOSTheme.textPrimary,
                    ),
                  ),
                ),
                if (disk.hasTemp) ...[
                  const Icon(CupertinoIcons.thermometer, size: 12, color: IOSTheme.textTertiary),
                  const SizedBox(width: 2),
                  Text(
                    '${disk.tempC!.toStringAsFixed(0)}°C',
                    style: TextStyle(
                      fontSize: 11,
                      color: disk.tempC! >= 80
                          ? IOSTheme.danger
                          : (disk.tempC! >= 65 ? IOSTheme.warning : IOSTheme.success),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Text(
                  '${disk.percent.toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 14,
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(CupertinoIcons.pencil, size: 14, color: IOSTheme.textTertiary),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              height: 4,
              decoration: BoxDecoration(
                color: IOSTheme.glassLight,
                borderRadius: BorderRadius.circular(2),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: (disk.percent / 100).clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [color, color.withOpacity(0.7)]),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                Text(
                  '${disk.usedGb.toStringAsFixed(1)} / ${disk.totalGb.toStringAsFixed(1)} GB',
                  style: const TextStyle(fontSize: 11, color: IOSTheme.textTertiary),
                ),
                if (disk.mount.isNotEmpty && disk.mount != '/$displayName')
                  Text(
                    '挂载 ${disk.mount}',
                    style: const TextStyle(fontSize: 10.5, color: IOSTheme.textTertiary),
                  ),
                if (disk.device.isNotEmpty)
                  Text(
                    disk.device,
                    style: const TextStyle(fontSize: 10.5, color: IOSTheme.textTertiary),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 编辑硬盘 sheet（iOS 风格：bottom sheet + CupertinoTextField + switch）
// 跟安卓 _EditDiskDialog 行为对齐
// ============================================================
class _EditDiskSheet extends StatefulWidget {
  final String serverId;
  final DiskEntry disk;
  final String? currentAlias;
  final bool isHidden;
  final MonitorStore store;
  const _EditDiskSheet({
    required this.serverId,
    required this.disk,
    required this.currentAlias,
    required this.isHidden,
    required this.store,
  });
  @override
  State<_EditDiskSheet> createState() => _EditDiskSheetState();
}

class _EditDiskSheetState extends State<_EditDiskSheet> {
  late final TextEditingController _ctrl;
  late bool _hidden;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.currentAlias ?? '');
    _hidden = widget.isHidden;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final ok = await widget.store.updateDiskConfig(
        widget.serverId,
        aliases: {widget.disk.mount: _ctrl.text.trim()},
        hidden: {widget.disk.mount: _hidden},
        // merge=true: 否则单条 map 会把别的盘的 alias / hidden 整个擦掉
        merge: true,
      );
      if (mounted) {
        if (ok) {
          Navigator.of(context).pop();
        } else {
          setState(() => _busy = false);
        }
      }
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = widget.disk.name.isNotEmpty
        ? widget.disk.name
        : (widget.disk.mount.isNotEmpty
            ? widget.disk.mount.split('/').last
            : widget.disk.device);
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFFFFFFF),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, MediaQuery.of(context).padding.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFE0E0E5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text(
            '编辑硬盘',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: IOSTheme.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            '挂载点 ${widget.disk.mount}  ·  设备 ${widget.disk.device}',
            style: const TextStyle(color: IOSTheme.textTertiary, fontSize: 11),
          ),
          const SizedBox(height: 18),
          const Text(
            '显示名称',
            style: TextStyle(fontSize: 12, color: IOSTheme.textTertiary, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          CupertinoTextField(
            controller: _ctrl,
            autofocus: true,
            placeholder: '默认：$placeholder',
            placeholderStyle: const TextStyle(color: IOSTheme.textTertiary, fontSize: 14),
            style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 15),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: IOSTheme.glassDark,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '在硬盘列表中隐藏',
                  style: TextStyle(fontSize: 14, color: IOSTheme.textPrimary),
                ),
              ),
              CupertinoSwitch(
                value: _hidden,
                onChanged: (v) => setState(() => _hidden = v),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  color: IOSTheme.glassDark,
                  borderRadius: BorderRadius.circular(10),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('取消', style: TextStyle(color: IOSTheme.textPrimary)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  color: IOSTheme.primary,
                  borderRadius: BorderRadius.circular(10),
                  onPressed: _busy ? null : _save,
                  child: _busy
                      ? const CupertinoActivityIndicator()
                      : const Text('保存', style: TextStyle(color: CupertinoColors.white, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
