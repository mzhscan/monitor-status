// Generic server detail page: adapts to NAS / VPS based on the AgentData
// shape coming back from the backend. Replaces the old hardcoded
// ServerDetailPage / UsVpsPage with one component that handles both.
//
// Layout (top to bottom):
//   - HardwareSummaryCard: server name, NAS/VPS chip, key-value config table
//   - CPU + Memory row (always)
//   - GPU card (if any)
//   - Disks (multi-entry, with per-row alias / hidden editing)
//   - Services card (active/inactive/failed translated)
//   - VPS section: 3xui clients / inbounds (only when kind == vps)

import 'package:flutter/material.dart';
import 'models.dart';
import 'store.dart';
import 'toast.dart';
import 'widgets.dart';

class DynamicServerPage extends StatelessWidget {
  final MonitorServer server;
  final MonitorStore store;
  const DynamicServerPage({super.key, required this.server, required this.store});

  @override
  Widget build(BuildContext context) {
    final agent = store.agentFor(server);
    return RefreshIndicator(
      color: const Color(0xFFFF6B95),
      backgroundColor: Colors.white,
      onRefresh: () async => Future.delayed(const Duration(milliseconds: 500)),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _Header(server: server, agent: agent),
          const SizedBox(height: 10),
          if (agent == null) _loadingCard() else ..._buildBody(agent),
          const SizedBox(height: 8),
          if (store.lastSuccessAt != null)
            Center(
              child: Text(
                '更新于 ${_fmtTime(store.lastSuccessAt!)}',
                style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildBody(AgentData agent) {
    final hw = agent.hardware;
    final cpu = hw?.cpu;
    final mem = hw?.memory;
    final gpu = hw?.gpu;
    final disks = hw?.disks ?? const <DiskEntry>[];

    return [
      _HardwareSummaryCard(
        agent: agent,
        cpu: cpu,
        mem: mem,
        gpu: gpu,
        disks: disks,
      ),
      const SizedBox(height: 10),
      IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _CpuCard(cpu: cpu, kind: agent.kind)),
            const SizedBox(width: 10),
            Expanded(child: _MemCard(mem: mem)),
          ],
        ),
      ),
      if (gpu != null && (gpu.hasUtil || gpu.hasTemp || gpu.hasMemory)) ...[
        const SizedBox(height: 10),
        _GpuCard(gpu: gpu),
      ],
      if (agent.isVps && agent.hasXui) ...[
        const SizedBox(height: 10),
        if (agent.xui!.error != null)
          _XuiErrorCard(error: agent.xui!.error!, agentName: agent.name)
        else
          _VpsSection(xui: agent.xui!, agentName: agent.name),
      ],
      // 硬盘放最下面（v2.4.18+）：以前在 GPU 之后，进 VPS 主机详情时得先
      // 翻过磁盘才能看到 3xui 客户端列表。挪到底部让"这台机器的核心数据"
      // 优先展示。
      if (disks.isNotEmpty) ...[
        const SizedBox(height: 10),
        _DisksCard(
          disks: disks,
          serverName: agent.name,
          serverId: agent.id,
          diskAliases: server.diskAliases,
          hiddenDisks: server.hiddenDisks,
          store: store,
        ),
      ],
    ];
  }

  static String _fmtTime(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';
  }

  Widget _loadingCard() {
    return const GlassCard(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF6B95))),
            SizedBox(width: 12),
            Text('正在采集数据…', style: TextStyle(color: Color(0xFF7A7A82), fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
// ============================================================
// Header
// ============================================================

class _Header extends StatelessWidget {
  final MonitorServer server;
  final AgentData? agent;
  const _Header({required this.server, required this.agent});

  @override
  Widget build(BuildContext context) {
    final isVps = agent?.isVps ?? false;
    final online = agent?.isLive ?? false;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF6B95), Color(0xFFFFB6C1)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isVps ? Icons.public_rounded : Icons.dns_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(server.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1A1A1A),
                        )),
                    const SizedBox(height: 2),
                    Text(
                      server.displayLocation,
                      style: const TextStyle(color: Color(0xFF7A7A82), fontSize: 12),
                    ),
                  ],
                ),
              ),
              _StatusBadge(online: online, secondsAgo: agent?.secondsAgo ?? -1),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _Chip(
                icon: isVps ? Icons.cloud_rounded : Icons.storage_rounded,
                text: isVps ? 'VPS' : 'NAS',
                bg: isVps ? const Color(0x1A4F8EF7) : const Color(0x1A10B981),
                fg: isVps ? const Color(0xFF4F8EF7) : const Color(0xFF10B981),
              ),
              _Chip(
                icon: server.isSsh ? Icons.terminal_rounded : Icons.http_rounded,
                text: server.isSsh ? 'SSH' : 'Agent',
                bg: const Color(0x1AFF6B95),
                fg: const Color(0xFFFF6B95),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool online;
  final int secondsAgo;
  const _StatusBadge({required this.online, required this.secondsAgo});

  @override
  Widget build(BuildContext context) {
    String label;
    Color color;
    if (online) {
      label = '在线';
      color = const Color(0xFF10B981);
    } else if (secondsAgo >= 0 && secondsAgo < 300) {
      label = '卡顿 ${secondsAgo}s';
      color = const Color(0xFFF59E0B);
    } else {
      label = '离线';
      color = const Color(0xFFE53935);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color bg;
  final Color fg;
  const _Chip({required this.icon, required this.text, required this.bg, required this.fg});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: fg.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fg, size: 12),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}// ============================================================
// Hardware summary card (always at the top of every detail page)
// ============================================================

class _HardwareSummaryCard extends StatelessWidget {
  final AgentData agent;
  final CpuInfo? cpu;
  final MemoryInfo? mem;
  final GpuInfo? gpu;
  final List<DiskEntry> disks;
  const _HardwareSummaryCard({
    required this.agent,
    required this.cpu,
    required this.mem,
    required this.gpu,
    required this.disks,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF6B95), Color(0xFFFFB6C1)],
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  agent.isVps ? Icons.public_rounded : Icons.dns_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(agent.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A),
                        )),
                    const SizedBox(height: 2),
                    Text(
                      agent.isVps ? 'VPS 主机' : 'NAS / 主机',
                      style: const TextStyle(color: Color(0xFF7A7A82), fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0x14000000)),
          const SizedBox(height: 12),
          _kv('CPU', _fmtCpu()),
          _kv('内存', _fmtMem()),
          _kv('显卡', _fmtGpu()),
          _kv('硬盘', _fmtDisks()),
          _kv('网络', _fmtNet()),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 48,
              child: Text(k, style: const TextStyle(color: Color(0xFF7A7A82), fontSize: 12)),
            ),
            Expanded(
              child: Text(v, style: const TextStyle(color: Color(0xFF1A1A1A), fontSize: 12.5)),
            ),
          ],
        ),
      );

  String _fmtCpu() {
    if (cpu == null) return '—';
    final parts = <String>[];
    if (cpu!.hasModel) {
      parts.add(cpu!.model);
    } else {
      parts.add('CPU');
    }
    if (cpu!.cores > 0) parts.add('${cpu!.cores} 核');
    if (cpu!.hasTemp) parts.add('${cpu!.tempC.toStringAsFixed(0)}°C');
    if (cpu!.percent > 0) parts.add('${cpu!.percent.toStringAsFixed(0)}%');
    return parts.join(' · ');
  }

  String _fmtMem() {
    if (mem == null || mem!.totalGb <= 0) return '—';
    return '${mem!.totalGb.toStringAsFixed(1)} GB · 已用 ${mem!.usedGb.toStringAsFixed(1)} GB · ${mem!.percent.toStringAsFixed(0)}%';
  }

  String _fmtGpu() {
    if (gpu == null || !gpu!.available) return '—';
    final model = (gpu!.model != null && gpu!.model!.isNotEmpty) ? gpu!.model! : 'GPU';
    final parts = <String>[model];
    if (gpu!.hasUtil) parts.add('${gpu!.percent!.toStringAsFixed(0)}%');
    if (gpu!.hasTemp) parts.add('${gpu!.tempC!.toStringAsFixed(0)}°C');
    if (gpu!.hasMemory) {
      parts.add('${(gpu!.usedMb! / 1024).toStringAsFixed(1)} / ${(gpu!.totalMb! / 1024).toStringAsFixed(1)} GB');
    }
    return parts.join(' · ');
  }

  String _fmtDisks() {
    if (disks.isEmpty) return '—';
    final totalTb = disks.fold<double>(0, (acc, d) => acc + d.totalGb) / 1024;
    final usedTb = disks.fold<double>(0, (acc, d) => acc + d.usedGb) / 1024;
    if (totalTb >= 1) {
      return '${disks.length} 块 · ${usedTb.toStringAsFixed(1)} / ${totalTb.toStringAsFixed(1)} TB';
    }
    final totalGb = disks.fold<double>(0, (acc, d) => acc + d.totalGb);
    final usedGb = disks.fold<double>(0, (acc, d) => acc + d.usedGb);
    return '${disks.length} 块 · ${usedGb.toStringAsFixed(1)} / ${totalGb.toStringAsFixed(1)} GB';
  }

  String _fmtNet() {
    final n = agent.hardware?.network;
    if (n == null) return '—';
    // Treat fully-zero network as "no data" rather than showing 0 MB.
    if (n.rxMb <= 0 && n.txMb <= 0 && n.rxBytes <= 0 && n.txBytes <= 0) return '—';
    final rxMb = n.rxMb > 0 ? n.rxMb : n.rxBytes / (1024 * 1024);
    final txMb = n.txMb > 0 ? n.txMb : n.txBytes / (1024 * 1024);
    if (rxMb >= 1024) {
      return '↓ ${(rxMb / 1024).toStringAsFixed(1)} GB  ↑ ${(txMb / 1024).toStringAsFixed(1)} GB';
    }
    return '↓ ${rxMb.toStringAsFixed(0)} MB  ↑ ${txMb.toStringAsFixed(0)} MB';
  }
}// ============================================================
// CPU card
// ============================================================

class _CpuCard extends StatelessWidget {
  final CpuInfo? cpu;
  final String kind;
  const _CpuCard({required this.cpu, required this.kind});

  @override
  Widget build(BuildContext context) {
    final pct = cpu?.percent ?? 0;
    final temp = cpu?.tempC ?? 0;
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.memory_rounded, size: 18, color: Color(0xFFFF6B95)),
              const SizedBox(width: 6),
              const Text('CPU',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A))),
              const Spacer(),
              if (cpu != null && cpu!.hasModel)
                Text('${cpu!.cores} 核',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A82))),
            ],
          ),
          const SizedBox(height: 8),
          UsageBar(
            label: '使用率',
            valueText: '${pct.toStringAsFixed(1)}%',
            percent: pct,
            icon: Icons.show_chart_rounded,
          ),
          if (temp > 0) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.thermostat_rounded, size: 14, color: Color(0xFF7A7A82)),
                const SizedBox(width: 4),
                Text('${temp.toStringAsFixed(0)}°C',
                    style: TextStyle(
                      fontSize: 12,
                      color: tempColor(temp),
                      fontWeight: FontWeight.w600,
                    )),
              ],
            ),
          ],
          if (cpu != null && cpu!.hasModel) ...[
            const SizedBox(height: 6),
            Text(cpu!.model,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5, color: Color(0xFF7A7A82))),
          ],
          const Spacer(),
        ],
      ),
    );
  }
}

// ============================================================
// Memory card
// ============================================================

class _MemCard extends StatelessWidget {
  final MemoryInfo? mem;
  const _MemCard({required this.mem});

  @override
  Widget build(BuildContext context) {
    final pct = mem?.percent ?? 0;
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.storage_rounded, size: 18, color: Color(0xFFFF6B95)),
              const SizedBox(width: 6),
              const Text('内存',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A))),
              const Spacer(),
              if (mem != null)
                Text('${mem!.totalGb.toStringAsFixed(1)} GB',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A82))),
            ],
          ),
          const SizedBox(height: 8),
          UsageBar(
            label: '使用率',
            valueText: '${pct.toStringAsFixed(0)}%',
            percent: pct,
            icon: Icons.show_chart_rounded,
          ),
          if (mem != null) ...[
            const SizedBox(height: 6),
            Text('已用 ${mem!.usedGb.toStringAsFixed(1)} GB',
                style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A82))),
          ],
          const Spacer(),
        ],
      ),
    );
  }
}

// ============================================================
// GPU card
// ============================================================

class _GpuCard extends StatelessWidget {
  final GpuInfo gpu;
  const _GpuCard({required this.gpu});

  @override
  Widget build(BuildContext context) {
    final util = gpu.percent ?? 0;
    final temp = gpu.tempC ?? 0;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.developer_board_rounded, size: 18, color: Color(0xFFFF6B95)),
              const SizedBox(width: 6),
              const Text('显卡',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A))),
              const Spacer(),
              if (gpu.hasMemory)
                Text(
                  gpu.usedMb! > 0
                      ? '${(gpu.usedMb! / 1024).toStringAsFixed(1)} / ${(gpu.totalMb! / 1024).toStringAsFixed(1)} GB'
                      : '${(gpu.totalMb! / 1024).toStringAsFixed(1)} GB',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A82)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (gpu.model != null && gpu.model!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(gpu.model!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A82))),
            ),
          if (gpu.hasUtil) ...[
            UsageBar(
              label: '使用率',
              valueText: '${util.toStringAsFixed(0)}%',
              percent: util,
              icon: Icons.show_chart_rounded,
            ),
            const SizedBox(height: 6),
          ],
          Row(
            children: [
              if (gpu.hasTemp)
                Expanded(
                  child: _Metric(
                    icon: Icons.thermostat_rounded,
                    label: '温度',
                    value: '${temp.toStringAsFixed(0)}°C',
                    color: tempColor(temp),
                  ),
                ),
              if (gpu.hasTemp && gpu.hasMemory && gpu.usedMb! > 0)
                const SizedBox(width: 8),
              if (gpu.hasMemory && gpu.usedMb! > 0)
                Expanded(
                  child: _Metric(
                    icon: Icons.memory_rounded,
                    label: '显存',
                    value: '${(gpu.usedMb! / 1024).toStringAsFixed(1)} GB',
                    color: const Color(0xFF7A7A82),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}// ============================================================
// Disks card + per-row alias/hidden editing
// ============================================================

class _DisksCard extends StatelessWidget {
  final List<DiskEntry> disks;
  final String serverName;
  final String serverId;
  final Map<String, String> diskAliases;
  final Map<String, bool> hiddenDisks;
  final MonitorStore store;
  const _DisksCard({
    required this.disks,
    required this.serverName,
    required this.serverId,
    required this.diskAliases,
    required this.hiddenDisks,
    required this.store,
  });

  @override
  Widget build(BuildContext context) {
    final visible = disks.where((d) => hiddenDisks[d.mount] != true).toList();
    final hiddenCount = disks.length - visible.length;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.save_rounded, size: 18, color: Color(0xFFFF6B95)),
              const SizedBox(width: 6),
              const Text('硬盘',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A))),
              const Spacer(),
              Text(
                hiddenCount > 0
                    ? '${visible.length} 块 / 已隐藏 $hiddenCount'
                    : '${visible.length} 块',
                style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A82)),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => _showDiskManager(context),
                borderRadius: BorderRadius.circular(8),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.tune_rounded, size: 16, color: Color(0xFFFF6B95)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('所有硬盘都已隐藏，点右上角齿轮恢复',
                  style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12)),
            )
          else
            for (var i = 0; i < visible.length; i++) ...[
              if (i > 0) const Divider(height: 18, color: Color(0x22000000)),
              _DiskRow(
                d: visible[i],
                alias: diskAliases[visible[i].mount],
                onTap: () => _editDisk(context, visible[i]),
              ),
            ],
        ],
      ),
    );
  }

  void _showDiskManager(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _DiskManagerSheet(
        serverId: serverId,
        disks: disks,
        diskAliases: diskAliases,
        hiddenDisks: hiddenDisks,
        store: store,
      ),
    );
  }

  void _editDisk(BuildContext context, DiskEntry d) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _EditDiskDialog(
        serverId: serverId,
        disk: d,
        currentAlias: diskAliases[d.mount],
        isHidden: hiddenDisks[d.mount] == true,
        store: store,
      ),
    );
  }
}

class _DiskRow extends StatelessWidget {
  final DiskEntry d;
  final String? alias;
  final VoidCallback? onTap;
  const _DiskRow({required this.d, this.alias, this.onTap});

  @override
  Widget build(BuildContext context) {
    final mountLeaf = d.mount == '/' ? '系统盘' : d.mount.split('/').last;
    final displayName = (alias != null && alias!.isNotEmpty)
        ? alias!
        : (d.name.isNotEmpty
            ? d.name
            : (mountLeaf.isNotEmpty ? mountLeaf : d.device));
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
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
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                ),
                if (d.hasTemp) ...[
                  const Icon(Icons.thermostat_rounded, size: 12, color: Color(0xFF7A7A82)),
                  const SizedBox(width: 2),
                  Text('${d.tempC!.toStringAsFixed(0)}°C',
                      style: TextStyle(fontSize: 11, color: tempColor(d.tempC!))),
                  const SizedBox(width: 10),
                ],
                Text('${d.percent.toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 14,
                      color: usageColor(d.percent),
                      fontWeight: FontWeight.w700,
                    )),
                const SizedBox(width: 4),
                const Icon(Icons.edit_outlined, size: 14, color: Color(0xFFB5B5BD)),
              ],
            ),
            const SizedBox(height: 4),
            UsageBar(
              label: '',
              valueText: '',
              percent: d.percent,
              icon: Icons.show_chart_rounded,
              showLabel: false,
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('${d.usedGb.toStringAsFixed(1)} / ${d.totalGb.toStringAsFixed(1)} GB',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A82))),
                if (d.mount.isNotEmpty && d.mount != '/$displayName')
                  Text('挂载 ${d.mount}',
                      style: const TextStyle(fontSize: 10.5, color: Color(0xFFB5B5BD))),
                if (d.device.isNotEmpty)
                  Text(d.device, style: const TextStyle(fontSize: 10.5, color: Color(0xFFB5B5BD))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}// ============================================================
// Disk manager bottom sheet — bulk rename / hide
// ============================================================

class _DiskManagerSheet extends StatefulWidget {
  final String serverId;
  final List<DiskEntry> disks;
  final Map<String, String> diskAliases;
  final Map<String, bool> hiddenDisks;
  final MonitorStore store;
  const _DiskManagerSheet({
    required this.serverId,
    required this.disks,
    required this.diskAliases,
    required this.hiddenDisks,
    required this.store,
  });

  @override
  State<_DiskManagerSheet> createState() => _DiskManagerSheetState();
}

class _DiskManagerSheetState extends State<_DiskManagerSheet> {
  late Map<String, String> _aliases;
  late Map<String, bool> _hidden;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _aliases = Map<String, String>.from(widget.diskAliases);
    _hidden = Map<String, bool>.from(widget.hiddenDisks);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final ok = await widget.store.updateDiskConfig(
        widget.serverId,
        aliases: _aliases,
        hidden: _hidden,
      );
      if (mounted) {
        AppToast.show(context, ok ? '已保存' : '保存失败，详见 logcat');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        AppToast.show(context, '保存失败：$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (ctx, scrollCtl) {
        return Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFFFF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFFFFFFF), width: 1.0),
            boxShadow: const [
              BoxShadow(color: Color(0x18000000), blurRadius: 14, offset: Offset(0, 4)),
            ],
          ),
          child: Column(
            children: [
              Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E5EA),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Row(
                  children: [
                    const Icon(Icons.tune_rounded, size: 18, color: Color(0xFFFF6B95)),
                    const SizedBox(width: 8),
                    const Text('管理硬盘显示',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A))),
                    const Spacer(),
                    TextButton(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                      child: const Text('取消', style: TextStyle(color: Color(0xFF7A7A82))),
                    ),
                    FilledButton(
                      onPressed: _busy ? null : _save,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFF6B95),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                      child: _busy
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('保存'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFFE5E5EA)),
              Expanded(
                child: ListView.separated(
                  controller: scrollCtl,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: widget.disks.length,
                  separatorBuilder: (_, __) => const Divider(height: 20, color: Color(0x14000000)),
                  itemBuilder: (ctx, i) {
                    final d = widget.disks[i];
                    final hidden = _hidden[d.mount] == true;
                    return _DiskManagerRow(
                      d: d,
                      alias: _aliases[d.mount] ?? '',
                      hidden: hidden,
                      onAliasChanged: (v) {
                        setState(() {
                          if (v.isEmpty) {
                            _aliases.remove(d.mount);
                          } else {
                            _aliases[d.mount] = v;
                          }
                        });
                      },
                      onHiddenChanged: (v) {
                        setState(() {
                          if (v) {
                            _hidden[d.mount] = true;
                          } else {
                            _hidden.remove(d.mount);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DiskManagerRow extends StatefulWidget {
  final DiskEntry d;
  final String alias;
  final bool hidden;
  final ValueChanged<String> onAliasChanged;
  final ValueChanged<bool> onHiddenChanged;
  const _DiskManagerRow({
    required this.d,
    required this.alias,
    required this.hidden,
    required this.onAliasChanged,
    required this.onHiddenChanged,
  });

  @override
  State<_DiskManagerRow> createState() => _DiskManagerRowState();
}

class _DiskManagerRowState extends State<_DiskManagerRow> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.alias);
  }

  @override
  void didUpdateWidget(covariant _DiskManagerRow old) {
    super.didUpdateWidget(old);
    if (old.alias != widget.alias && _ctrl.text != widget.alias) {
      _ctrl.text = widget.alias;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = widget.d.name.isNotEmpty
        ? widget.d.name
        : (widget.d.mount.isNotEmpty ? widget.d.mount.split('/').last : widget.d.device);
    return Opacity(
      opacity: widget.hidden ? 0.5 : 1.0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  placeholder.isEmpty ? widget.d.mount : placeholder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
              ),
              if (widget.d.hasTemp) ...[
                const Icon(Icons.thermostat_rounded, size: 12, color: Color(0xFF7A7A82)),
                const SizedBox(width: 2),
                Text('${widget.d.tempC!.toStringAsFixed(0)}°C',
                    style: TextStyle(fontSize: 11, color: tempColor(widget.d.tempC!))),
                const SizedBox(width: 8),
              ],
              Text('${widget.d.percent.toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 13,
                    color: usageColor(widget.d.percent),
                    fontWeight: FontWeight.w700,
                  )),
              const SizedBox(width: 10),
              _MiniSwitch(
                value: widget.hidden,
                onChanged: widget.onHiddenChanged,
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _ctrl,
            onChanged: widget.onAliasChanged,
            style: const TextStyle(fontSize: 13, color: Color(0xFF1A1A1A)),
            decoration: InputDecoration(
              isDense: true,
              hintText: '显示名称（默认：$placeholder）',
              hintStyle: const TextStyle(color: Color(0xFFB5B5BD), fontSize: 12),
              filled: true,
              fillColor: const Color(0xFFF7F7FA),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E5EA), width: 0.6),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFFF6B95), width: 1.2),
              ),
              suffixIcon: _ctrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16, color: Color(0xFF7A7A82)),
                      onPressed: () {
                        _ctrl.clear();
                        widget.onAliasChanged('');
                      },
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _MiniSwitch({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 34, height: 20,
        decoration: BoxDecoration(
          color: value ? const Color(0xFFFF6B95) : const Color(0xFFE0E0E5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16, height: 16,
            margin: const EdgeInsets.all(2),
            decoration: const BoxDecoration(color: Color(0xFFFFFFFF), shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// Single-disk rename dialog
// ============================================================

class _EditDiskDialog extends StatefulWidget {
  final String serverId;
  final DiskEntry disk;
  final String? currentAlias;
  final bool isHidden;
  final MonitorStore store;
  const _EditDiskDialog({
    required this.serverId,
    required this.disk,
    required this.currentAlias,
    required this.isHidden,
    required this.store,
  });

  @override
  State<_EditDiskDialog> createState() => _EditDiskDialogState();
}

class _EditDiskDialogState extends State<_EditDiskDialog> {
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
        // (store.updateDiskConfig 内部：merge=false 时是替换)
        merge: true,
      );
      if (mounted) {
        AppToast.show(context, ok ? '已保存' : '保存失败，详见 logcat');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        AppToast.show(context, '保存失败：$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = widget.disk.name.isNotEmpty
        ? widget.disk.name
        : (widget.disk.mount.isNotEmpty
            ? widget.disk.mount.split('/').last
            : widget.disk.device);
    return AlertDialog(
      backgroundColor: const Color(0xFFFFFFFF),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      title: const Text('编辑硬盘',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A))),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('挂载点 ${widget.disk.mount}  ·  设备 ${widget.disk.device}',
                style: const TextStyle(color: Color(0xFF7A7A82), fontSize: 11)),
            const SizedBox(height: 12),
            const Text('显示名称',
                style: TextStyle(fontSize: 12, color: Color(0xFF7A7A82), fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: InputDecoration(
                isDense: true,
                hintText: '默认：$placeholder',
                hintStyle: const TextStyle(color: Color(0xFFB5B5BD), fontSize: 13),
                filled: true,
                fillColor: const Color(0xFFF7F7FA),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFE5E5EA), width: 0.6),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFFF6B95), width: 1.2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Expanded(
                  child: Text('在此设备详情页隐藏',
                      style: TextStyle(fontSize: 13, color: Color(0xFF2C2C2C))),
                ),
                _MiniSwitch(
                  value: _hidden,
                  onChanged: (v) { if (!_busy) setState(() => _hidden = v); },
                ),
              ],
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(color: Color(0xFF7A7A82))),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFFF6B95),
            disabledBackgroundColor: const Color(0xFFFFB6C1),
          ),
          child: _busy
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('保存'),
        ),
      ],
    );
  }
}// ============================================================
// Services card
// ============================================================
// VPS section: 3xui clients / inbounds
// ============================================================

/// 3xui 采集失败时的提示卡（v2.4.17+）。
/// 之前 agent 端把 CollectXUI 错误静默吞掉，app 只能看到 "没 xui 字段"
/// 分不清是没装 3x-ui 还是 db 读失败。现在 agent 把错误塞进 xui._error，
/// app 这里渲染一个红卡片让 user 知道具体原因。
class _XuiErrorCard extends StatelessWidget {
  final String error;
  final String agentName;
  const _XuiErrorCard({required this.error, required this.agentName});
  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0x1AE53935),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.warning_amber_rounded,
                  color: Color(0xFFE53935),
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '3xui 数据采集失败',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0x33E53935), width: 0.5),
            ),
            child: SelectableText(
              error,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF1A1A1A),
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '排查步骤：',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF7A7A82),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '1. 确认 3x-ui 已安装（systemctl status x-ui）\n'
            '2. 确认数据库存在：/etc/x-ui/x-ui.db\n'
            '3. 看 agent 日志：journalctl -u server-monitor-agent -f',
            style: TextStyle(
              fontSize: 11.5,
              color: Color(0xFF7A7A82),
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _VpsSection extends StatefulWidget {
  final XuiInfo xui;
  final String agentName;
  const _VpsSection({required this.xui, required this.agentName});

  static String fmtGb(double gb) {
    if (gb >= 1024) return '${(gb / 1024).toStringAsFixed(2)} TB';
    if (gb < 1) return '${(gb * 1024).toStringAsFixed(0)} MB';
    return '${gb.toStringAsFixed(1)} GB';
  }

  @override
  State<_VpsSection> createState() => _VpsSectionState();
}

enum _ClientSort { total, down, up }

class _VpsSectionState extends State<_VpsSection> {
  _ClientSort _sort = _ClientSort.total;

  @override
  Widget build(BuildContext context) {
    final xui = widget.xui;
    final sorted = _sortedClients(xui.clients);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.people_alt_rounded, size: 18, color: Color(0xFFFF6B95)),
              const SizedBox(width: 6),
              const Text('3X-UI 客户端',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A))),
            ],
          ),
          const SizedBox(height: 10),
          // Three colored summary tiles at the top (Bug 5)
          Row(
            children: [
              Expanded(
                child: _Metric(
                  icon: Icons.circle,
                  label: '在线',
                  value: '${xui.onlineCount}/${xui.totalClients}',
                  color: const Color(0xFF10B981),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Metric(
                  icon: Icons.south_rounded,
                  label: '下行',
                  value: _VpsSection.fmtGb(xui.totalDownGb),
                  color: const Color(0xFF10B981),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Metric(
                  icon: Icons.north_rounded,
                  label: '上行',
                  value: _VpsSection.fmtGb(xui.totalUpGb),
                  color: const Color(0xFFFF6B95),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (xui.inbounds.isNotEmpty) ...[
            const Text('入站',
                style: TextStyle(fontSize: 12, color: Color(0xFF7A7A82), fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            for (final ib in xui.inbounds) _InboundRow(ib: ib),
            const SizedBox(height: 10),
          ],
          if (xui.clients.isNotEmpty) ...[
            const Text('客户端',
                style: TextStyle(fontSize: 12, color: Color(0xFF7A7A82), fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            // Clickable column headers replace the old sort buttons (Bug 6)
            _ClientHeader(sort: _sort, onSort: (s) => setState(() => _sort = s)),
            for (var i = 0; i < sorted.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: Color(0x14000000)),
              _ClientRow(c: sorted[i]),
            ],
          ],
        ],
      ),
    );
  }

  List<XuiClient> _sortedClients(List<XuiClient> clients) {
    final sorted = List<XuiClient>.from(clients);
    sorted.sort((a, b) {
      double va, vb;
      switch (_sort) {
        case _ClientSort.down:
          va = a.downGb;
          vb = b.downGb;
          break;
        case _ClientSort.up:
          va = a.upGb;
          vb = b.upGb;
          break;
        case _ClientSort.total:
          va = a.totalGb;
          vb = b.totalGb;
          break;
      }
      return vb.compareTo(va); // descending
    });
    return sorted;
  }
}

class _InboundRow extends StatelessWidget {
  final XuiInbound ib;
  const _InboundRow({required this.ib});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
              color: ib.enable ? const Color(0xFF10B981) : const Color(0xFF9CA3AF),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ib.remark.isNotEmpty ? ib.remark : ':${ib.port}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF2C2C2C)),
            ),
          ),
          Text('↓${_VpsSection.fmtGb(ib.downGb)}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF10B981), fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text('↑${_VpsSection.fmtGb(ib.upGb)}',
              style: const TextStyle(fontSize: 11, color: Color(0xFFFF6B95), fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _ClientHeader extends StatelessWidget {
  final _ClientSort sort;
  final ValueChanged<_ClientSort> onSort;
  const _ClientHeader({required this.sort, required this.onSort});

  Widget _sortable(String label, _ClientSort s, {double width = 48}) {
    final active = sort == s;
    final color = active ? const Color(0xFFFF6B95) : const Color(0xFF7A7A82);
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
              const Icon(Icons.arrow_downward_rounded, size: 10, color: Color(0xFFFF6B95)),
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
              color: Color(0xFF7A7A82),
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
                    color: Color(0xFF7A7A82),
                    fontWeight: FontWeight.w600)),
          ),
          _sortable('总计', _ClientSort.total),
          _sortable('下行', _ClientSort.down),
          _sortable('上行', _ClientSort.up),
          _static('72h'),
          _static('最近活跃'),
        ],
      ),
    );
  }
}

/// Convert a unix-ms timestamp to a compact "X 秒/分/时/天 前" string.
/// Returns "从未" if the timestamp is 0, "刚刚" if it's in the future.
String _formatLastOnline(int ms) {
  if (ms <= 0) return '从未';
  final sec = ((DateTime.now().millisecondsSinceEpoch - ms) / 1000).round();
  if (sec < 0) return '刚刚';
  if (sec < 60) return '${sec}秒前';
  if (sec < 3600) return '${sec ~/ 60}分前';
  if (sec < 86400) return '${sec ~/ 3600}时前';
  return '${sec ~/ 86400}天前';
}

class _ClientRow extends StatelessWidget {
  final XuiClient c;
  const _ClientRow({required this.c});
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
                  ? const Color(0xFF10B981)
                  : (c.enable ? const Color(0xFFF59E0B) : const Color(0xFF9CA3AF)),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 5,
            child: Text(
              c.email,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF1A1A1A)),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              _VpsSection.fmtGb(c.totalGb),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, color: Color(0xFF1A1A1A), fontWeight: FontWeight.w600),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              _VpsSection.fmtGb(c.downGb),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, color: Color(0xFF10B981)),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              _VpsSection.fmtGb(c.upGb),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, color: Color(0xFFFF6B95)),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              c.traffic72hGb == null ? '—' : _VpsSection.fmtGb(c.traffic72hGb!),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                color: c.traffic72hGb == null
                    ? const Color(0xFFB5B5BD)
                    : const Color(0xFF2C2C2C),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              _formatLastOnline(c.lastOnline),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: c.online
                    ? const Color(0xFF10B981)
                    : const Color(0xFF7A7A82),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _Metric({required this.icon, required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
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