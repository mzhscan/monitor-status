// 把 dart:io / package:http 的异常翻译成对用户友好的中文。

import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;

/// 用户面向的错误信息。永远返回中文。
String explainError(Object e) {
  if (e is SocketException) {
    final msg = e.message;
    if (msg.contains('Connection refused')) {
      return '连接被拒：agent 没在跑，或端口/防火墙拦了';
    }
    if (msg.contains('Network is unreachable') ||
        msg.contains('No route to host')) {
      return '网络不通：手机和 server 之间没有路由';
    }
    if (msg.contains('Failed host lookup') ||
        msg.contains('No address associated with hostname')) {
      return 'DNS 解析失败：域名打错或者 DNS 不通';
    }
    if (msg.contains('Connection timed out') || msg.contains('timed out')) {
      return '连接超时：网络太慢或 server 没响应';
    }
    if (msg.contains('Connection reset')) {
      return '连接被重置：运营商/防火墙拦了，或 server 主动断开';
    }
    return '网络错误：$msg';
  }
  if (e is HandshakeException) {
    final m = e.message;
    if (m.contains('CERTIFICATE_VERIFY_FAILED') &&
        m.contains('Hostname mismatch')) {
      return 'TLS 主机名不匹配：cert 跟 URL 对不上';
    }
    if (m.contains('CERTIFICATE_VERIFY_FAILED') &&
        m.contains('unable to get local issuer')) {
      return '证书不被系统信任（自签/未知 CA）';
    }
    if (m.contains('CERTIFICATE_VERIFY_FAILED')) {
      return '证书校验失败';
    }
    if (m.contains('bad_certificate') || m.contains('certificate')) {
      return '证书错误：$m';
    }
    return 'TLS 握手失败：$m';
  }
  if (e is TimeoutException) {
    return '请求超时（默认 6 秒）';
  }
  if (e is HttpException) {
    return 'HTTP 错误：${e.message}';
  }
  if (e is FormatException) {
    return '数据格式错误：${e.message}';
  }
  if (e is http.ClientException) {
    final m = e.message;
    if (m.contains('Connection refused')) {
      return '连接被拒：agent 没在跑，或端口/防火墙拦了';
    }
    if (m.contains('timed out') || m.contains('TimeoutException')) {
      return '请求超时';
    }
    if (m.contains('SocketException')) {
      return '网络错误：$m';
    }
    return '网络错误：$m';
  }
  // 兜底
  return e.toString();
}

/// 用于 test() 的返回结果：除了错误文字，还要标记是否需要弹信任框。
/// 这样调用方不用 try-catch 各种异常。
class AgentTestResult {
  final bool success;
  final String? message;
  final String? error;
  final bool tlsUntrusted;

  const AgentTestResult({
    required this.success,
    this.message,
    this.error,
    this.tlsUntrusted = false,
  });

  factory AgentTestResult.ok(String message) =>
      AgentTestResult(success: true, message: message);
  factory AgentTestResult.fail(String error, {bool tlsUntrusted = false}) =>
      AgentTestResult(
        success: false,
        error: error,
        tlsUntrusted: tlsUntrusted,
      );
}
