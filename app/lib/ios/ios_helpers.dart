// iOS 27 风格通用 helpers
//
// 跟安卓对齐的"判定状态用 lastSuccessMs"逻辑（v2.4.22+）。原 iOS 的
// `online` 布尔基于 AgentData.secondsAgo × 1000 < 120000，而
// AgentData.secondsAgo 是 agent 自己采集时刻（time.Now()），跟 app 是否
// 真正连得上无关 —— agent 挂几小时 app 也显示"在线"。
// 现在用 store.lastSuccessMs（app poll 成功时间）：失败时不变，
// 自然会"卡 Xs / 离线"，跟 app 端实际连接状态一致。
//
// 这个文件里的函数给 machines 页 + detail 页共用，逻辑必须跟
// Android 那边 lib/widgets.dart 的 StatusBadge 完全一致。

import 'package:flutter/cupertino.dart';
import 'ios_theme.dart';

/// 状态判定结果（跟 Android 的 StatusBadge 接口对齐）
class ServerStatus {
  final String label; // "加载中" / "在线" / "卡 Xs" / "离线"
  final Color color;
  final int secondsAgo; // -1 = 还没成功过
  const ServerStatus({required this.label, required this.color, required this.secondsAgo});
}

/// 从 lastSuccessMs（app 端 poll 成功时间）算状态。跟安卓 StatusBadge 同语义。
ServerStatus computeStatus(int? lastSuccessMs) {
  int sa;
  if (lastSuccessMs == null || lastSuccessMs == 0) {
    sa = -1;
  } else {
    sa = ((DateTime.now().millisecondsSinceEpoch - lastSuccessMs) / 1000).round();
  }
  if (sa < 0) {
    return const ServerStatus(label: '加载中', color: IOSTheme.textTertiary, secondsAgo: -1);
  } else if (sa < 30) {
    return ServerStatus(label: '在线', color: IOSTheme.success, secondsAgo: sa);
  } else if (sa < 300) {
    return ServerStatus(label: '卡 ${sa}s', color: IOSTheme.warning, secondsAgo: sa);
  } else {
    return ServerStatus(label: '离线', color: IOSTheme.danger, secondsAgo: sa);
  }
}

/// 使用率颜色（跟安卓 usageColor 对齐）
Color usageColor(double pct) {
  if (pct >= 85) return IOSTheme.danger;
  if (pct >= 60) return IOSTheme.warning;
  return IOSTheme.success;
}

/// 温度颜色（跟安卓 tempColor 对齐）
Color tempColor(double t) {
  if (t >= 80) return IOSTheme.danger;
  if (t >= 65) return IOSTheme.warning;
  if (t > 0) return IOSTheme.success;
  return IOSTheme.textTertiary;
}

/// HH:MM:SS 本地时间格式化
String fmtTime(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';
}

/// 状态指示 pill（iOS 27 风格：胶囊 + 颜色 + 圆点）
/// 跟安卓 StatusBadge 视觉风格不同（iOS 用模糊胶囊 + 白字），但语义一致。
class StatusPill extends StatelessWidget {
  final ServerStatus status;
  const StatusPill({super.key, required this.status});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: status.color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: status.color.withOpacity(0.4), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(color: status.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            status.label,
            style: TextStyle(
              color: status.color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
