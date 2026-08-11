// iOS 风格"关于"页（bottom sheet）
//
// 跟安卓 about_page.dart 对齐：
//   - 版本号
//   - 检查更新（拉 GitHub release）
//   - GitHub 链接（仓库 / 部署文档）
//   - 受信任的证书管理（展开列表 + 删除）
//   - 清空所有数据（红色 destructive 按钮）
//
// 视觉保持 iOS 27 Liquid Glass。

import 'package:flutter/cupertino.dart';
import '../check_update.dart';
import '../models.dart';
import '../store.dart';
import '../trusted_certs.dart';
import 'ios_theme.dart';
import 'ios_glass.dart';

class IOSAboutSheet extends StatelessWidget {
  const IOSAboutSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => const IOSAboutSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Color(0xFF0A0E1A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 1.0,
        minChildSize: 1.0,
        maxChildSize: 1.0,
        expand: false,
        builder: (ctx, scroll) {
          return ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A3A3A),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Center(
                child: Text(
                  '星黎监控',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: IOSTheme.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  'v${CheckUpdate.currentVersion} (${CheckUpdate.currentBuild})',
                  style: const TextStyle(color: IOSTheme.textTertiary, fontSize: 13),
                ),
              ),
              const SizedBox(height: 24),
              const _SectionTitle('检查更新'),
              const _CheckUpdateRow(),
              const SizedBox(height: 18),
              const _SectionTitle('项目主页'),
              _LinkRow(
                icon: CupertinoIcons.chevron_left_slash_chevron_right,
                title: 'GitHub 仓库',
                subtitle: 'github.com/mzhscan/monitor-status',
                onTap: () => CheckUpdate.openReleasePage(context),
              ),
              _LinkRow(
                icon: CupertinoIcons.book,
                title: '部署文档 (README)',
                subtitle: '一键部署 agent / 添加服务器步骤',
                onTap: () => CheckUpdate.openReadme(context),
              ),
              const SizedBox(height: 18),
              const _SectionTitle('高级 / 排错'),
              const _TrustedCertsRow(),
              const SizedBox(height: 8),
              const _ResetAllRow(),
              const SizedBox(height: 24),
              const Center(
                child: Text(
                  'MIT License · mzhscan',
                  style: TextStyle(color: IOSTheme.textTertiary, fontSize: 11),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          color: IOSTheme.textTertiary,
          fontWeight: FontWeight.w600,
        ),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassContainer(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(icon, color: IOSTheme.primary, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14, color: IOSTheme.textPrimary, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 11, color: IOSTheme.textTertiary)),
                ],
              ),
            ),
            const Icon(CupertinoIcons.arrow_up_right_square, color: IOSTheme.textTertiary, size: 16),
          ],
        ),
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
    return GlassContainer(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _busy
                  ? const CupertinoActivityIndicator(radius: 9)
                  : const Icon(CupertinoIcons.arrow_down_circle, color: IOSTheme.primary, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('检查新版本', style: TextStyle(fontSize: 14, color: IOSTheme.textPrimary, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      _result == null
                          ? '点击从 GitHub 拉取最新 release'
                          : _result!.summary,
                      style: TextStyle(
                        fontSize: 11,
                        color: _result?.isError == true
                            ? IOSTheme.danger
                            : (_result?.isNewer == true ? IOSTheme.warning : IOSTheme.textTertiary),
                      ),
                    ),
                  ],
                ),
              ),
              CupertinoButton(
                padding: EdgeInsets.zero,
                minSize: 0,
                onPressed: _busy ? null : _check,
                child: const Icon(CupertinoIcons.refresh, color: IOSTheme.primary, size: 18),
              ),
            ],
          ),
          if (_result != null && _result!.isNewer) ...[
            const SizedBox(height: 10),
            Container(height: 1, color: IOSTheme.glassBorder),
            const SizedBox(height: 10),
            Text(
              '新版本: v${_result!.latestTag}',
              style: const TextStyle(fontWeight: FontWeight.w600, color: IOSTheme.textPrimary),
            ),
            const SizedBox(height: 4),
            Text(
              _result!.body ?? '',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: IOSTheme.textTertiary),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => CheckUpdate.openReleasePage(context),
                child: const Text('打开 release', style: TextStyle(color: IOSTheme.primary, fontSize: 13)),
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
  bool _expanded = false;

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
    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        children: [
          CupertinoButton(
            padding: const EdgeInsets.symmetric(vertical: 10),
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Row(
              children: [
                const Icon(CupertinoIcons.shield_lefthalf_fill, color: IOSTheme.primary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('受信任的证书', style: TextStyle(fontSize: 14, color: IOSTheme.textPrimary, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 2),
                      Text(
                        _trusted.isEmpty
                            ? '无（说明服务器都用的公共 CA 证书）'
                            : '已为 ${_trusted.length} 个 agent 信任证书',
                        style: const TextStyle(fontSize: 11, color: IOSTheme.textTertiary),
                      ),
                    ],
                  ),
                ),
                Icon(
                  _expanded ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
                  color: IOSTheme.textTertiary,
                  size: 14,
                ),
              ],
            ),
          ),
          if (_expanded && _trusted.isNotEmpty) ...[
            Container(height: 1, color: IOSTheme.glassBorder),
            const SizedBox(height: 4),
            for (final entry in _trusted.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(entry.key, style: const TextStyle(fontSize: 12, color: IOSTheme.textPrimary)),
                          const SizedBox(height: 2),
                          Text(
                            entry.value,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 9, color: IOSTheme.textTertiary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minSize: 0,
                      onPressed: () async {
                        await TrustedCerts.untrust(entry.key);
                        await _refresh();
                      },
                      child: const Icon(CupertinoIcons.delete, color: IOSTheme.danger, size: 18),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ResetAllRow extends StatelessWidget {
  const _ResetAllRow();
  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      onTap: () async {
        final ok = await showCupertinoDialog<bool>(
          context: context,
          builder: (ctx) => CupertinoAlertDialog(
            title: const Text('确认清空？'),
            content: const Text('将删除本机所有已添加的服务器和受信任的证书。\nagent 本身不受影响，重启后还可以重新添加。'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
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
            await showCupertinoDialog<void>(
              context: context,
              builder: (ctx) => CupertinoAlertDialog(
                content: const Text('已清空所有本地数据'),
                actions: [
                  CupertinoDialogAction(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('好'),
                  ),
                ],
              ),
            );
          }
        }
      },
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const Icon(CupertinoIcons.trash, color: IOSTheme.danger, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  '清空所有数据',
                  style: TextStyle(fontSize: 14, color: IOSTheme.danger, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 2),
                Text(
                  '删除所有 agent 配置 + 信任的证书（不可恢复）',
                  style: TextStyle(fontSize: 11, color: IOSTheme.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
