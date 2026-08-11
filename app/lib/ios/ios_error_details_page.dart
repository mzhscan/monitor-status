// iOS 风格错误详情页
//
// 跟安卓 error_page.dart 对齐：
//   - 顶部"概览"卡片：聚合错误（store.error）+ 最近成功时间
//   - 每台出错 server 一张卡：名字 + URL + 最后响应时间 + 错误信息 + 单台重试
//   - 底部"重试全部"按钮
//   - AppBar 右上角"清空"按钮
//
// 视觉保持 iOS 27 Liquid Glass（GlassContainer + BackdropFilter）。

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors, SelectableText;
import '../models.dart';
import '../store.dart';
import 'ios_helpers.dart';
import 'ios_theme.dart';
import 'ios_glass.dart';

class IOSErrorDetailsPage extends StatelessWidget {
  final MonitorStore store;
  const IOSErrorDetailsPage({super.key, required this.store});

  /// 整页是否需要展示：有任意错误就展示，否则空。
  static bool hasErrors(MonitorStore store) {
    if (store.error != null && store.error!.isNotEmpty) return true;
    for (final s in store.servers) {
      if (store.errorFor(s) != null && store.errorFor(s)!.isNotEmpty) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: Colors.transparent,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: IOSTheme.glassDark,
        border: null,
        middle: const Text('错误详情'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () {
            store.clearError();
            Navigator.of(context).pop();
          },
          child: const Text('清空', style: TextStyle(color: IOSTheme.primary, fontSize: 15)),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            IOSTheme.paddingL, IOSTheme.paddingM,
            IOSTheme.paddingL, 100,
          ),
          children: [
            _buildSummaryCard(),
            const SizedBox(height: 12),
            ..._buildPerServerCards(),
            const SizedBox(height: 20),
            SizedBox(
              height: 46,
              child: CupertinoButton(
                color: IOSTheme.primary,
                borderRadius: BorderRadius.circular(12),
                onPressed: () async {
                  if (context.mounted) Navigator.of(context).pop();
                  await store.retryAll();
                },
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.refresh, size: 18),
                    SizedBox(width: 6),
                    Text('重试全部', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard() {
    final hasAggregate = store.error != null && store.error!.isNotEmpty;
    return GlassContainer(
      padding: const EdgeInsets.all(IOSTheme.paddingL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasAggregate ? CupertinoIcons.exclamationmark_triangle : CupertinoIcons.checkmark_alt_circle,
                size: 18,
                color: hasAggregate ? IOSTheme.danger : IOSTheme.success,
              ),
              const SizedBox(width: 8),
              Text(
                hasAggregate ? '总体异常' : '当前无异常',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: hasAggregate ? IOSTheme.danger : IOSTheme.success,
                ),
              ),
              const Spacer(),
              if (store.lastSuccessAt != null)
                Text(
                  '最近成功：${fmtTime(store.lastSuccessAt!)}',
                  style: const TextStyle(fontSize: 11, color: IOSTheme.textTertiary),
                ),
            ],
          ),
          if (hasAggregate) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: IOSTheme.danger.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: IOSTheme.danger.withOpacity(0.4), width: 0.5),
              ),
              child: SelectableText(
                store.error!,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: IOSTheme.textPrimary,
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildPerServerCards() {
    final out = <Widget>[];
    for (final s in store.orderedServers) {
      final err = store.errorFor(s);
      if (err == null || err.isEmpty) continue;
      out.add(_buildServerCard(s, err));
      out.add(const SizedBox(height: 10));
    }
    if (out.isEmpty) return const [];
    return [
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(
          '服务器详情',
          style: TextStyle(
            fontSize: 12,
            color: IOSTheme.textTertiary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      ...out,
    ];
  }

  Widget _buildServerCard(MonitorServer s, String err) {
    final lastSuccessMs = store.lastSuccessFor(s)?.millisecondsSinceEpoch;
    final sa = lastSuccessMs != null && lastSuccessMs > 0
        ? ((DateTime.now().millisecondsSinceEpoch - lastSuccessMs) / 1000).round()
        : 0;
    return GlassContainer(
      padding: const EdgeInsets.all(IOSTheme.paddingL - 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: IOSTheme.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                color: IOSTheme.primary.withOpacity(0.18),
                borderRadius: BorderRadius.circular(8),
                minSize: 0,
                onPressed: () => store.pollServer(s),
                child: const Text(
                  '重试',
                  style: TextStyle(color: IOSTheme.primary, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (s.agentUrl != null) ...[
            const SizedBox(height: 4),
            Text(
              s.agentUrl!,
              style: const TextStyle(fontSize: 11, color: IOSTheme.textTertiary, fontFamily: 'monospace'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (sa > 0) ...[
            const SizedBox(height: 4),
            Text(
              '最后一次响应：$sa 秒前',
              style: const TextStyle(fontSize: 11, color: IOSTheme.textTertiary),
            ),
          ],
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: IOSTheme.danger.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: IOSTheme.danger.withOpacity(0.4), width: 0.5),
            ),
            child: SelectableText(
              err,
              style: const TextStyle(
                fontSize: 12,
                color: IOSTheme.textPrimary,
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
