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
import 'package:flutter/material.dart' show LinearProgressIndicator;
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
      // 修：背景改白色（之前 Colors.transparent 让水平滑入 0.4s 期间透出总览页内容，
      // 看起来'内容重叠'）。iOS 27 标准的 modal push 转场本身就有动画，
      // 但 page 本身必须 opaque（modal 是覆盖语义，不是叠加）
      backgroundColor: const Color(0xFFFFFFFF),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: IOSTheme.glassDark,  // nav bar 保留 80% 白，保留 Liquid Glass 感
        border: null,
        middle: Text(widget.server.name),
        // 修：右上角只保留编辑按钮
        //  - 刷新按钮去掉（已经有 CupertinoSliverRefreshControl 下拉刷新）
        //  - 保留 loading 指示器（store.isLoading 时显示转圈）
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
            // v2.4.28+：用 LinearProgressIndicator（跟安卓 UsageBar 一致），
            // solid fill + 明确 track。之前自画渐变 fill 0.7 alpha 会糊掉
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (pct.clamp(0, 100)) / 100,
                minHeight: 8,
                backgroundColor: IOSTheme.trackBackground,
                valueColor: AlwaysStoppedAnimation<Color>(color),
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
    // 跟安卓 _VpsSection 对齐：3 个彩色 metric + 实时总流量卡 + inbounds 列表
    // + 可排序客户端表头 + 丰富客户端行 + 底部说明
    return _XuiVpsSection(xui: xui);
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
            const SizedBox(height: 6),
            // v2.4.28+：用 LinearProgressIndicator（跟安卓 UsageBar 一致），
            // 跟资源占用大条同样改
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (disk.percent.clamp(0, 100)) / 100,
                minHeight: 8,
                backgroundColor: IOSTheme.trackBackground,
                valueColor: AlwaysStoppedAnimation<Color>(color),
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

// ============================================================
// 3X-UI VPS section（跟安卓 _VpsSection 对齐：3 彩色 metric + 实时总流量卡
// + inbounds 列表 + 可排序客户端表头 + 丰富客户端行 + 底部说明）
// ============================================================

enum _XuiClientSort { total, down, up }

class _XuiVpsSection extends StatefulWidget {
  final XuiInfo xui;
  const _XuiVpsSection({required this.xui});
  @override
  State<_XuiVpsSection> createState() => _XuiVpsSectionState();
}

class _XuiVpsSectionState extends State<_XuiVpsSection> {
  _XuiClientSort _sort = _XuiClientSort.total;

  static String fmtGb(double gb) {
    if (gb >= 1024) return '${(gb / 1024).toStringAsFixed(2)} TB';
    if (gb < 1) return '${(gb * 1024).toStringAsFixed(0)} MB';
    return '${gb.toStringAsFixed(1)} GB';
  }

  static String _formatObservedAt(int sec) {
    if (sec <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000).toLocal();
    return '${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}:${d.second.toString().padLeft(2, "0")}';
  }

  // "X秒/分/时/天 前"（跟安卓 _formatLastOnline 一样）
  static String _formatLastOnline(int ms) {
    if (ms <= 0) return '从未';
    final sec = ((DateTime.now().millisecondsSinceEpoch - ms) / 1000).round();
    if (sec < 0) return '刚刚';
    if (sec < 60) return '${sec}秒前';
    if (sec < 3600) return '${sec ~/ 60}分前';
    if (sec < 86400) return '${sec ~/ 3600}时前';
    return '${sec ~/ 86400}天前';
  }

  List<XuiClient> _sortedClients(List<XuiClient> clients) {
    final sorted = List<XuiClient>.from(clients);
    sorted.sort((a, b) {
      double va, vb;
      switch (_sort) {
        case _XuiClientSort.down:
          va = a.downGb;
          vb = b.downGb;
          break;
        case _XuiClientSort.up:
          va = a.upGb;
          vb = b.upGb;
          break;
        case _XuiClientSort.total:
          va = a.totalGb;
          vb = b.totalGb;
          break;
      }
      return vb.compareTo(va); // 降序
    });
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final xui = widget.xui;
    final sorted = _sortedClients(xui.clients);
    final inbound = xui.inboundTotal;

    return GlassContainer(
      padding: const EdgeInsets.all(IOSTheme.paddingL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Row(
            children: [
              const Icon(CupertinoIcons.person_2_fill, size: 18, color: IOSTheme.primary),
              const SizedBox(width: 6),
              const Text('3X-UI 客户端',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: IOSTheme.textPrimary)),
            ],
          ),
          const SizedBox(height: 10),
          // 3 个彩色 metric tiles（在线/下行/上行）
          Row(
            children: [
              Expanded(
                child: _XuiMetric(
                  icon: CupertinoIcons.circle_fill,
                  label: '在线',
                  value: '${xui.onlineCount}/${xui.totalClients}',
                  color: IOSTheme.success,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _XuiMetric(
                  icon: CupertinoIcons.arrow_down,
                  label: '下行',
                  value: fmtGb(xui.totalDownGb),
                  color: IOSTheme.info,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _XuiMetric(
                  icon: CupertinoIcons.arrow_up,
                  label: '上行',
                  value: fmtGb(xui.totalUpGb),
                  color: IOSTheme.primary,
                ),
              ),
            ],
          ),
          // 实时总流量卡（蓝色渐变 + xray 实时数据 + 入口数）
          if (inbound != null) ...[
            const SizedBox(height: 10),
            _XuiRealTimeCard(total: inbound),
          ],
          const SizedBox(height: 12),
          // Inbounds 列表
          if (xui.inbounds.isNotEmpty) ...[
            const Text('入站',
                style: TextStyle(fontSize: 12, color: IOSTheme.textTertiary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            for (final ib in xui.inbounds) _XuiInboundRow(ib: ib),
            const SizedBox(height: 10),
          ],
          // 客户端列表
          if (xui.clients.isNotEmpty) ...[
            const Text('客户端',
                style: TextStyle(fontSize: 12, color: IOSTheme.textTertiary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            _XuiClientHeader(sort: _sort, onSort: (s) => setState(() => _sort = s)),
            for (var i = 0; i < sorted.length; i++) ...[
              if (i > 0) Container(height: 1, color: IOSTheme.glassBorder, margin: const EdgeInsets.symmetric(vertical: 2)),
              _XuiClientRow(
                c: sorted[i],
                formatLastOnline: _formatLastOnline,
              ),
            ],
          ],
          // 底部说明
          if (xui.observedAt > 0) ...[
            const SizedBox(height: 10),
            Text(
              '数据采集于 ${_formatObservedAt(xui.observedAt)} · 3x-ui 客户端流量需断开时才更新（滞后 20+ 分钟）',
              style: const TextStyle(fontSize: 10.5, color: IOSTheme.textHint, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

/// 3X-UI 彩色 metric tile（在线/下行/上行，带背景色 + icon + 数字）
class _XuiMetric extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _XuiMetric({required this.icon, required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3), width: 0.5),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: TextStyle(fontSize: 10.5, color: color.withOpacity(0.85))),
                Text(value,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 实时总流量卡（蓝色渐变 + 入口数 + ↑↓）
class _XuiRealTimeCard extends StatelessWidget {
  final InboundTotal total;
  const _XuiRealTimeCard({required this.total});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0x1A4F8EF7), Color(0x0D4F8EF7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x334F8EF7), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(CupertinoIcons.bolt_fill, size: 14, color: IOSTheme.info),
              const SizedBox(width: 6),
              const Text(
                'VPS 主机总流量',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: IOSTheme.info),
              ),
              const Spacer(),
              Text(
                '${total.inboundsCount} 个入口',
                style: const TextStyle(fontSize: 10, color: IOSTheme.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(CupertinoIcons.arrow_down, size: 14, color: IOSTheme.success),
                    const SizedBox(width: 4),
                    Text(
                      _XuiVpsSectionState.fmtGb(total.downGb),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: IOSTheme.textPrimary),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    const Icon(CupertinoIcons.arrow_up, size: 14, color: IOSTheme.primary),
                    const SizedBox(width: 4),
                    Text(
                      _XuiVpsSectionState.fmtGb(total.upGb),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: IOSTheme.textPrimary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Inbounds 单行：dot + 名称 + ↓↑ 流量
class _XuiInboundRow extends StatelessWidget {
  final XuiInbound ib;
  const _XuiInboundRow({required this.ib});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
              color: ib.enable ? IOSTheme.success : IOSTheme.textHint,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ib.remark.isNotEmpty ? ib.remark : ':${ib.port}',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: IOSTheme.textSecondary),
            ),
          ),
          Text('↓${_XuiVpsSectionState.fmtGb(ib.downGb)}',
              style: const TextStyle(fontSize: 11, color: IOSTheme.info, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text('↑${_XuiVpsSectionState.fmtGb(ib.upGb)}',
              style: const TextStyle(fontSize: 11, color: IOSTheme.primary, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// 客户端表头（可点击排序：总计 / 下行 / 上行 / 72h / 最近活跃）
class _XuiClientHeader extends StatelessWidget {
  final _XuiClientSort sort;
  final ValueChanged<_XuiClientSort> onSort;
  const _XuiClientHeader({required this.sort, required this.onSort});

  Widget _sortable(String label, _XuiClientSort s, {double width = 48}) {
    final active = sort == s;
    final color = active ? IOSTheme.primary : IOSTheme.textTertiary;
    return GestureDetector(
      onTap: () => onSort(s),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 10.5,
                    color: color,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600)),
            if (active) ...[
              const SizedBox(width: 2),
              const Icon(CupertinoIcons.arrow_down, size: 10, color: IOSTheme.primary),
            ],
          ],
        ),
      ),
    );
  }

  Widget _static(String label, {double width = 56}) {
    return SizedBox(
      width: width,
      child: Text(label,
          textAlign: TextAlign.right,
          style: const TextStyle(
              fontSize: 10.5,
              color: IOSTheme.textTertiary,
              fontWeight: FontWeight.w600)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: 14), // dot + spacer
          const Expanded(
            flex: 5,
            child: Text('客户端',
                style: TextStyle(
                    fontSize: 10.5,
                    color: IOSTheme.textTertiary,
                    fontWeight: FontWeight.w600)),
          ),
          _sortable('总计', _XuiClientSort.total),
          _sortable('下行', _XuiClientSort.down),
          _sortable('上行', _XuiClientSort.up),
          _static('72h'),
          _static('最近活跃'),
        ],
      ),
    );
  }
}

/// 客户端单行：dot + email + 总计/下行/上行/72h/最近活跃
class _XuiClientRow extends StatelessWidget {
  final XuiClient c;
  final String Function(int ms) formatLastOnline;
  const _XuiClientRow({required this.c, required this.formatLastOnline});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
              color: c.online
                  ? IOSTheme.success
                  : (c.enable ? IOSTheme.warning : IOSTheme.textHint),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 5,
            child: Text(
              c.email,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: IOSTheme.textPrimary),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              _XuiVpsSectionState.fmtGb(c.totalGb),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, color: IOSTheme.textPrimary, fontWeight: FontWeight.w600),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              _XuiVpsSectionState.fmtGb(c.downGb),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, color: IOSTheme.info),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              _XuiVpsSectionState.fmtGb(c.upGb),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, color: IOSTheme.primary),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              c.traffic72hGb == null ? '—' : _XuiVpsSectionState.fmtGb(c.traffic72hGb!),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                color: c.traffic72hGb == null ? IOSTheme.textHint : IOSTheme.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              formatLastOnline(c.lastOnline),
              textAlign: TextAlign.right,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: c.online ? IOSTheme.success : IOSTheme.textTertiary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
