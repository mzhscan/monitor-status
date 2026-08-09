// 错误详情页：从 AppBar 右上角红 icon 点进来，展示聚合错误 +
// 每个出错 server 的具体错误。支持「重试全部」/「清空错误」。

import 'package:flutter/material.dart';
import 'models.dart';
import 'store.dart';
import 'toast.dart';

class ErrorDetailsPage extends StatelessWidget {
  final MonitorStore store;
  const ErrorDetailsPage({super.key, required this.store});

  /// 整页是否需要展示：有任意错误就展示，否则空。
  static bool hasErrors(MonitorStore store) {
    if (store.error != null && store.error!.isNotEmpty) return true;
    for (final s in store.servers) {
      if (store.errorFor(s) != null) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFEEF2),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: const BackButton(color: Color(0xFF2C2C2C)),
        title: const Text(
          '错误详情',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A1A),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              store.clearError();
              AppToast.show(context, '已清空');
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.cleaning_services_outlined, size: 18, color: Color(0xFF7A7A82)),
            label: const Text('清空', style: TextStyle(color: Color(0xFF7A7A82), fontSize: 13)),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // 顶部"概览"卡片
          _buildSummaryCard(context),
          const SizedBox(height: 12),
          // 每台出错 server
          ..._buildPerServerCards(context),
          const SizedBox(height: 20),
          // 重试全部按钮
          SizedBox(
            height: 46,
            child: FilledButton.icon(
              onPressed: () async {
                Navigator.of(context).pop(); // 关掉本页，回到总览
                await store.retryAll();
              },
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试全部', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B95),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(BuildContext context) {
    final hasAggregate = store.error != null && store.error!.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x1A000000), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasAggregate ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
                size: 18,
                color: hasAggregate ? const Color(0xFFE53935) : const Color(0xFF10B981),
              ),
              const SizedBox(width: 8),
              Text(
                hasAggregate ? '总体异常' : '当前无异常',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: hasAggregate ? const Color(0xFFE53935) : const Color(0xFF10B981),
                ),
              ),
              const Spacer(),
              if (store.lastSuccessAt != null)
                Text(
                  '最近成功：${_fmtTime(store.lastSuccessAt!)}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                ),
            ],
          ),
          if (hasAggregate) ...[
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
                store.error!,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF1A1A1A),
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

  List<Widget> _buildPerServerCards(BuildContext context) {
    final out = <Widget>[];
    for (final s in store.orderedServers) {
      final err = store.errorFor(s);
      if (err == null || err.isEmpty) continue;
      out.add(_buildServerCard(context, s, err));
      out.add(const SizedBox(height: 10));
    }
    if (out.isEmpty) return const [];
    return [
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(
          '服务器详情',
          style: TextStyle(fontSize: 12, color: Color(0xFF7A7A82), fontWeight: FontWeight.w600),
        ),
      ),
      ...out,
    ];
  }

  Widget _buildServerCard(BuildContext context, MonitorServer s, String err) {
    final agent = store.agentFor(s);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x1A000000), width: 0.5),
      ),
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
                    color: Color(0xFF1A1A1A),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              // 单独重试该 server
              TextButton(
                onPressed: () {
                  store.pollServer(s);
                  AppToast.show(context, '已发起重试');
                },
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: const Color(0xFFFF6B95),
                ),
                child: const Text('重试', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (s.agentUrl != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                s.agentUrl!,
                style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A82), fontFamily: 'monospace'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (agent != null && agent.secondsAgo >= 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                agent.secondsAgo == 0
                    ? '刚刚有响应'
                    : '最后一次响应：${agent.secondsAgo} 秒前',
                style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A82)),
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0x33E53935), width: 0.5),
            ),
            child: SelectableText(
              err,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF1A1A1A),
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';
  }
}
