// iOS 风格设置页
//
// 把之前 about sheet 里的内容（检查更新 / GitHub 链接 / 受信任证书 / 清空所有数据）
// 直接展开到设置页，不再弹 modal。所有 section 都在一个 ListView 里
// 滚动显示，保留 iOS 27 风格（GlassContainer + 紧凑 nav bar）。

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Divider;
import '../check_update.dart';
import '../models.dart';
import '../store.dart';
import '../trusted_certs.dart';
import 'ios_error_details_page.dart';
import 'ios_glass.dart';
import 'ios_theme.dart';

class IOSSettingsPage extends StatefulWidget {
  final MonitorStore store;
  const IOSSettingsPage({super.key, required this.store});

  @override
  State<IOSSettingsPage> createState() => _IOSSettingsPageState();
}

class _IOSSettingsPageState extends State<IOSSettingsPage> {
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
    final hasErrors = IOSErrorDetailsPage.hasErrors(widget.store);

    return Column(
      children: [
        // 紧凑 nav bar（不带大标题）—— iOS 27 风格
        const CupertinoNavigationBar(
          backgroundColor: Color(0xFFFFFFFF),
          border: null,
          middle: Text(
            '设置',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: IOSTheme.textPrimary,
            ),
          ),
        ),
        // 内容：所有 section 都在一个 ListView 里
        Expanded(
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              IOSTheme.paddingL, 0,  // 修：顶部 padding=0 让第一张卡紧贴 nav bar 下沿
              IOSTheme.paddingL, 140,  // 留出浮动 tab bar 空间
            ),
            children: [
              // === 检查更新 ===
              const _SectionTitle('检查更新'),
              const _CheckUpdateRow(),
              const SizedBox(height: 18),
              // === 项目主页 ===
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
              // === 高级 / 排错 ===
              const _SectionTitle('高级 / 排错'),
              const _TrustedCertsRow(),
              const SizedBox(height: 8),
              _ResetAllRow(store: widget.store),
              // === 错误查看入口（有时显示） ===
              if (hasErrors) ...[
                const SizedBox(height: 18),
                const _SectionTitle('错误'),
                GlassContainer(
                  padding: const EdgeInsets.symmetric(horizontal: IOSTheme.paddingL, vertical: 4),
                  child: _row(
                    icon: CupertinoIcons.exclamationmark_circle,
                    iconColor: IOSTheme.danger,
                    label: '错误详情',
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: IOSTheme.danger.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('有错误', style: TextStyle(color: IOSTheme.danger, fontSize: 11, fontWeight: FontWeight.w600)),
                    ),
                    onTap: () => Navigator.of(context).pushNamed('/error-details'),
                  ),
                ),
              ],
              // === 信息（最底部） ===
              const SizedBox(height: 18),
              const _SectionTitle('信息'),
              GlassContainer(
                padding: const EdgeInsets.all(IOSTheme.paddingL),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _infoRow('版本', 'v${widget.store.appVersion} (${CheckUpdate.currentBuild})'),
                    _infoRow('机器数', '${widget.store.servers.length}'),
                    _infoRow('受信任证书', '${widget.store.trustedCertCount}'),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Center(
                child: Text(
                  'MIT License · mzhscan',
                  style: TextStyle(color: IOSTheme.textTertiary, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row({required IconData icon, required String label, Color? iconColor, Widget? trailing, VoidCallback? onTap}) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: iconColor ?? IOSTheme.primary, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 15))),
            if (trailing != null) ...[trailing, const SizedBox(width: 4)],
            const Icon(CupertinoIcons.chevron_right, color: IOSTheme.textTertiary, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 80, child: Text(k, style: const TextStyle(color: IOSTheme.textTertiary, fontSize: 12))),
          Expanded(child: Text(v, style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 12), overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

// ============================================================
// 下面是从 ios_about_sheet.dart 移过来的 widgets（修：直接展开到 settings 页，
// 不用弹 modal sheet）
// ============================================================

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
  final MonitorStore store;
  const _ResetAllRow({required this.store});
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
        if (ok != true || !context.mounted) return;
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
