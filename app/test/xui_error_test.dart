// 验证 v2.4.17+ XuiInfo 错误信息暴露逻辑：
// 1. xui 字段不存在（没装 3x-ui）→ xui=null, kind='nas'
// 2. xui 字段存在且有数据 → xui=正常, error=null, kind='vps'
// 3. xui 字段存在但 _error 有值（采集失败）→ xui=有, error=有, kind='vps'

import 'package:flutter_test/flutter_test.dart';
import 'package:monitor_status/models.dart';

void main() {
  group('XuiInfo._error handling (v2.4.17+)', () {
    test('no xui field → kind nas, xui null', () {
      final d = AgentData.fromJson(<String, dynamic>{
        'agent_name': 'mzhhua',
        'timestamp': 1700000000,
        'hardware': <String, dynamic>{},
        'services': [],
      });
      expect(d.kind, 'nas');
      expect(d.xui, isNull);
      expect(d.isVps, isFalse);
    });

    test('xui with data → kind vps, xui non-null, error null', () {
      final d = AgentData.fromJson(<String, dynamic>{
        'agent_name': 'mzhhua',
        'timestamp': 1700000000,
        'hardware': <String, dynamic>{},
        'xui': <String, dynamic>{
          'online_count': 1,
          'total_clients': 2,
          'total_up_gb': 0.01,
          'total_down_gb': 0.04,
          'clients': [
            <String, dynamic>{
              'email': 'a',
              'enable': true,
              'up_bytes': 100,
              'down_bytes': 200,
              'up_mb': 0.0,
              'down_mb': 0.0,
              'up_gb': 0.0,
              'down_gb': 0.0,
              'last_online': 1700000000000,
            }
          ],
          'inbounds': [],
        },
        'services': [],
      });
      expect(d.kind, 'vps');
      expect(d.xui, isNotNull);
      expect(d.xui!.error, isNull);
      expect(d.xui!.totalClients, 2);
      expect(d.xui!.clients.length, 1);
      expect(d.xui!.inbounds, isEmpty);
      expect(d.isVps, isTrue);
    });

    test('xui with _error → kind vps, xui non-null, error set', () {
      final d = AgentData.fromJson(<String, dynamic>{
        'agent_name': 'mzhhua',
        'timestamp': 1700000000,
        'hardware': <String, dynamic>{},
        'xui': <String, dynamic>{
          '_error': '读 client_traffics 失败: database is locked',
        },
        'services': [],
      });
      // 即便采集失败，只要 xui 字段存在，机器仍标 vps
      // （区分"没装 3x-ui"和"装了但读不到"）
      expect(d.kind, 'vps');
      expect(d.xui, isNotNull);
      expect(d.xui!.error, '读 client_traffics 失败: database is locked');
      // 失败时 clients/inbounds 是空（agent 端没填）
      expect(d.xui!.totalClients, 0);
      expect(d.xui!.clients, isEmpty);
      expect(d.xui!.inbounds, isEmpty);
      expect(d.isVps, isTrue);
    });

    test('xui with empty _error string → treated as null (no error)', () {
      final d = AgentData.fromJson(<String, dynamic>{
        'agent_name': 'mzhhua',
        'timestamp': 1700000000,
        'hardware': <String, dynamic>{},
        'xui': <String, dynamic>{
          '_error': '',
          'total_clients': 0,
        },
        'services': [],
      });
      expect(d.xui!.error, isNull);
    });
  });
}
