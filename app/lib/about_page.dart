// "关于" 页面：版本 / 检查更新 / GitHub 链接 / 重置数据

import 'package:flutter/material.dart';
import 'check_update.dart';
import 'trusted_certs.dart';
import 'store.dart';
import 'models.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => const AboutPage(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scroll) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFFFFFFF),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(color: Color(0x14000000), blurRadius: 18, offset: Offset(0, -3)),
            ],
          ),
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
              const Center(
                child: Text('星黎监控',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A1A))),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text('v${CheckUpdate.currentVersion} (${CheckUpdate.currentBuild})',
                    style: const TextStyle(color: Color(0xFF7A7A82), fontSize: 13)),
              ),
              const SizedBox(height: 24),
              _section('检查更新'),
              const _CheckUpdateRow(),
              const SizedBox(height: 18),
              _section('项目主页'),
              _LinkRow(
                icon: Icons.code_rounded,
                title: 'GitHub 仓库',
                subtitle: 'github.com/mzhscan/monitor-status',
                onTap: () => CheckUpdate.openReleasePage(context),
              ),
              _LinkRow(
                icon: Icons.book_rounded,
                title: '部署文档 (README)',
                subtitle: '一键部署 agent / 添加服务器步骤',
                onTap: () => CheckUpdate.openReadme(context),
              ),
              const SizedBox(height: 18),
              _section('高级 / 排错'),
              const _TrustedCertsRow(),
              const SizedBox(height: 8),
              const _ResetAllRow(),
              const SizedBox(height: 24),
              const Center(
                child: Text(
                  'MIT License · mzhscan',
                  style: TextStyle(color: Color(0xFFB5B5BD), fontSize: 11),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
            fontSize: 12, color: Color(0xFF7A7A82), fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _LinkRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7FA),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(icon, color: const Color(0xFFFF6B95)),
        title: Text(title, style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A1A))),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A82))),
        trailing: const Icon(Icons.open_in_new_rounded, size: 16, color: Color(0xFFB5B5BD)),
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class _CheckUpdateRow extends StatefulWidget {
  const _CheckUpdateRow();
  @override
  State<_CheckUpdateRow> createState() => _CheckUpdateRowState();
}

class _CheckUpdateRowState extends State<_CheckUpdateRow> {
  CheckUpdateResult? _result;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0F5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x33FFB6C1)),
      ),
      child: Column(
        children: [
          ListTile(
            leading: _busy
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF6B95)),
                  )
                : const Icon(Icons.system_update_alt_rounded, color: Color(0xFFFF6B95)),
            title: const Text('检查新版本',
                style: TextStyle(fontSize: 14, color: Color(0xFF1A1A1A), fontWeight: FontWeight.w600)),
            subtitle: _result == null
                ? const Text('点击从 GitHub 拉取最新 release',
                    style: TextStyle(fontSize: 11, color: Color(0xFF7A7A82)))
                : Text(_result!.summary,
                    style: TextStyle(
                        fontSize: 11,
                        color: _result!.isError
                            ? const Color(0xFFE53935)
                            : const Color(0xFF10B981))),
            trailing: const Icon(Icons.refresh_rounded, color: Color(0xFFFF6B95), size: 18),
            onTap: _busy ? null : _check,
          ),
          if (_result != null && _result!.isNewer) ...[
            const Divider(height: 1, color: Color(0x33FFB6C1)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('新版本: v${_result!.latestTag}',
                      style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A))),
                  const SizedBox(height: 4),
                  Text(_result!.body ?? '', maxLines: 4, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Color(0xFF7A7A82))),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => CheckUpdate.openReleasePage(context),
                      icon: const Icon(Icons.open_in_new_rounded, size: 14),
                      label: const Text('打开 release'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final r = await CheckUpdate.fetchLatest();
    if (!mounted) return;
    setState(() {
      _result = r;
      _busy = false;
    });
  }
}

class _TrustedCertsRow extends StatefulWidget {
  const _TrustedCertsRow();
  @override
  State<_TrustedCertsRow> createState() => _TrustedCertsRowState();
}

class _TrustedCertsRowState extends State<_TrustedCertsRow> {
  Map<String, String> _trusted = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final m = await TrustedCerts.all();
    if (!mounted) return;
    setState(() => _trusted = m);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7FA),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ExpansionTile(
        leading: const Icon(Icons.verified_user_rounded, color: Color(0xFFFF6B95)),
        title: const Text('受信任的证书', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          _trusted.isEmpty
              ? '无（说明服务器都用的公共 CA 证书）'
              : '已为 ${_trusted.length} 个 agent 信任证书',
          style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A82)),
        ),
        children: [
          for (final entry in _trusted.entries)
            ListTile(
              dense: true,
              title: Text(entry.key, style: const TextStyle(fontSize: 12)),
              subtitle: Text(entry.value,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 9, color: Color(0xFF7A7A82))),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Color(0xFFE53935)),
                onPressed: () async {
                  await TrustedCerts.untrust(entry.key);
                  await _refresh();
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ResetAllRow extends StatelessWidget {
  const _ResetAllRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x33E53935)),
      ),
      child: ListTile(
        leading: const Icon(Icons.delete_forever_rounded, color: Color(0xFFE53935)),
        title: const Text('清空所有数据',
            style: TextStyle(fontSize: 14, color: Color(0xFFE53935), fontWeight: FontWeight.w600)),
        subtitle: const Text('删除所有 agent 配置 + 信任的证书（不可恢复）',
            style: TextStyle(fontSize: 11, color: Color(0xFF7A7A82))),
        onTap: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('确认清空？'),
              content: const Text('将删除本机所有已添加的服务器和受信任的证书。\nagent 本身不受影响，重启后还可以重新添加。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('清空'),
                ),
              ],
            ),
          );
          if (ok == true && context.mounted) {
            final store = context.monitor;
            for (final s in List<MonitorServer>.from(store.servers)) {
              await store.deleteServer(s.id);
            }
            final trusted = await TrustedCerts.all();
            for (final url in trusted.keys) {
              await TrustedCerts.untrust(url);
            }
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已清空所有本地数据')),
              );
            }
          }
        },
      ),
    );
  }
}
