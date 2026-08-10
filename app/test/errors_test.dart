// 验证 v2.4.25+ explainError 错误信息汉化：
// 1. Exception("HTTP 502") → 不出现英文 "Exception: HTTP 502"，应该看到中文
// 2. Exception("HTTP 503") → agent 数据未就绪提示
// 3. Exception("HTTP 401") → token 无效提示
// 4. Exception("foo") → 去掉 "Exception: " 前缀
// 5. 其他 dart:io 异常 → 已汉化（回归测试）

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monitor_status/errors.dart';

void main() {
  group('explainError 异常汉化（v2.4.25+）', () {
    test('Exception("HTTP 502") → 不出现英文 Exception: 前缀', () {
      final msg = explainError(Exception('agent 返回 HTTP 502'));
      // 不能出现 "Exception: ..." 这种英文原始堆栈
      expect(msg, isNot(startsWith('Exception: ')));
      // 必须包含中文 + HTTP 502
      expect(msg, contains('HTTP 502'));
      expect(msg, contains('agent'));
    });

    test('Exception("HTTP 503") → agent 数据未就绪提示', () {
      final msg = explainError(Exception('agent 返回 HTTP 503'));
      expect(msg, contains('HTTP 503'));
      expect(msg, contains('agent'));
    });

    test('Exception("HTTP 401") → token 无效提示', () {
      final msg = explainError(Exception('agent 返回 HTTP 401'));
      expect(msg, contains('HTTP 401'));
      expect(msg, contains('token'));
    });

    test('Exception("HTTP 404") → 路径不存在提示', () {
      final msg = explainError(Exception('agent 返回 HTTP 404'));
      expect(msg, contains('HTTP 404'));
    });

    test('Exception("foo bar") → 去掉 "Exception: " 前缀，剩中文部分', () {
      final msg = explainError(Exception('foo bar'));
      // "Exception: foo bar" → 应该变成 "foo bar"
      expect(msg, isNot(startsWith('Exception:')));
      expect(msg, equals('foo bar'));
    });

    test('SocketException(Connection refused) → 已汉化（回归）', () {
      final msg = explainError(
        const SocketException('Connection refused'),
      );
      expect(msg, contains('连接被拒'));
    });

    test('TimeoutException → 已汉化（回归）', () {
      final msg = explainError(TimeoutException('test'));
      expect(msg, contains('超时'));
    });

    test('HandshakeException(CERTIFICATE_VERIFY_FAILED + Hostname mismatch) → 已汉化（回归）', () {
      final msg = explainError(
        const HandshakeException(
          'CERTIFICATE_VERIFY_FAILED: Hostname mismatch',
        ),
      );
      expect(msg, contains('主机名不匹配'));
    });
  });
}
