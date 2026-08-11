// iOS 风格设置页

import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../check_update.dart';
import '../store.dart';
import 'ios_theme.dart';
import 'ios_glass.dart';

class IOSSettingsPage extends StatefulWidget {
  final MonitorStore store;
  const IOSSettingsPage({super.key, required this.store});

  @override
  State<IOSSettingsPage> createState() => _IOSSettingsPageState();
}

class _IOSSettingsPageState extends State<IOSSettingsPage> {
  CheckUpdateResult? _updateResult;
  bool _checking = false;
  String _checkResult = '';

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

  Future<void> _checkUpdate() async {
    setState(() {
      _checking = true;
      _checkResult = '检查中…';
    });
    try {
      final r = await CheckUpdate.fetchLatest();
      setState(() {
        _updateResult = r;
        _checkResult = r.summary;
      });
    } catch (e) {
      setState(() => _checkResult = '检查失败：$e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        const CupertinoSliverNavigationBar(
          largeTitle: Text('设置'),
          backgroundColor: IOSTheme.glassDark,
          border: null,
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            IOSTheme.paddingL, IOSTheme.paddingS,
            IOSTheme.paddingL, 100,
          ),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              // 信任的证书
              GlassContainer(
                padding: const EdgeInsets.symmetric(horizontal: IOSTheme.paddingL, vertical: 8),
                child: Column(
                  children: [
                    _row(
                      icon: CupertinoIcons.shield_lefthalf_fill,
                      label: '受信任的证书',
                      trailing: Text('${widget.store.trustedCertCount}', style: const TextStyle(color: IOSTheme.textTertiary)),
                    ),
                    const Divider(color: IOSTheme.glassBorder, height: 1),
                    _row(
                      icon: CupertinoIcons.refresh,
                      label: '检查更新',
                      trailing: _checking
                          ? const CupertinoActivityIndicator(radius: 9)
                          : const Icon(CupertinoIcons.chevron_right, color: IOSTheme.textTertiary, size: 16),
                      onTap: _checking ? null : _checkUpdate,
                    ),
                  ],
                ),
              ),
              if (_checkResult.isNotEmpty) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    _checkResult,
                    style: TextStyle(
                      color: _updateResult?.isNewer == true ? IOSTheme.warning : IOSTheme.textTertiary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              // 关于
              GlassContainer(
                padding: const EdgeInsets.all(IOSTheme.paddingL),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('关于', style: TextStyle(color: IOSTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                    const SizedBox(height: 12),
                    _infoRow('版本', 'v${widget.store.appVersion}'),
                    _infoRow('机器数', '${widget.store.servers.length}'),
                    _infoRow('最近错误', widget.store.error ?? '无'),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _row({required IconData icon, required String label, Widget? trailing, VoidCallback? onTap}) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: IOSTheme.primary, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 15))),
            if (trailing != null) trailing,
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
          SizedBox(width: 70, child: Text(k, style: const TextStyle(color: IOSTheme.textTertiary, fontSize: 12))),
          Expanded(child: Text(v, style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 12), overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}
