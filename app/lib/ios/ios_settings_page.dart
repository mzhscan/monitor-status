// iOS 风格设置页
//
// 跟安卓的 about_page + settings 杂项对齐：
//   - 关于（版本 / 检查更新 / GitHub 链接 / 受信任的证书 / 清空所有数据）
//   - 错误查看入口（store.error 有时显示）
//
// 视觉保持 iOS 27 Liquid Glass（GlassContainer + BackdropFilter）。

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Divider;
import 'ios_about_sheet.dart';
import 'ios_error_details_page.dart';
import 'ios_theme.dart';
import 'ios_glass.dart';
import '../store.dart';

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
              // 关于入口
              GlassContainer(
                padding: const EdgeInsets.symmetric(horizontal: IOSTheme.paddingL, vertical: 4),
                child: Column(
                  children: [
                    _row(
                      icon: CupertinoIcons.info_circle,
                      label: '关于 / 检查更新 / 重置',
                      onTap: () => IOSAboutSheet.show(context),
                    ),
                    if (hasErrors) ...[
                      const Divider(color: IOSTheme.glassBorder, height: 1),
                      _row(
                        icon: CupertinoIcons.exclamationmark_circle,
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
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 信息
              GlassContainer(
                padding: const EdgeInsets.all(IOSTheme.paddingL),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('信息', style: TextStyle(color: IOSTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                    const SizedBox(height: 12),
                    _infoRow('版本', 'v${widget.store.appVersion}'),
                    _infoRow('机器数', '${widget.store.servers.length}'),
                    _infoRow('受信任证书', '${widget.store.trustedCertCount}'),
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
