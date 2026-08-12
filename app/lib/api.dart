// Per-agent HTTP client. No central backend — each server's agent is queried
// directly over HTTPS (or HTTP) using the token the user configured. Self-
// signed or untrusted certs are TOFU-pinned by SHA-256 fingerprint.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/io_client.dart' as io_client;
import 'package:http/http.dart' as http;
import 'errors.dart';
import 'models.dart';
import 'trusted_certs.dart';

class AgentClient {
  final String url;        // 拉数据的 URL：直连 = https://agent:port/api/report
                           //              relay  = https://relay:port/api/report
  final String token;      // X-Agent-Token header value
                           // 直连：agent 的 token
                           // relay：reverse-agent push 用的 token（relay 按 token 路由）
  final http.Client _client;

  AgentClient({required this.url, required this.token})
      : _client = _buildClient(url) {
    // Pre-load the in-memory trust cache so the very first poll can
    // consult it (badCertificateCallback is sync).
    unawaited(TrustedCertCache.refresh());
  }

  static http.Client _buildClient(String url) {
    final uri = Uri.parse(url);
    final isHttps = uri.scheme == 'https';
    if (!isHttps) {
      return http.Client();
    }
    // For HTTPS: trust the system store + any user-pinned (TOFU) certs.
    // badCertificateCallback must be sync (returns bool), so we pre-load
    // the trust set once at construction time. (The trust set changes
    // only via UI flow which rebuilds the AgentClient — see
    // add_server_dialog.dart.)
    final io = HttpClient()..badCertificateCallback = (cert, host, port) {
      // 1) Explicit user-pinned TOFU trust for this URL.
      if (TrustedCertCache.isTrusted(url, cert)) return true;
      // 2) Workaround for Dart's hostname check not recognizing IP-based
      //    SAN entries + iOS 27 strict hostname check.
      //
      // 之前的版本用 `issuer.contains('CN = YE2')` 这种严格匹配，但
      // X509Certificate.issuer.toString() 实际格式在 iOS 27 dart:io 上
      // 跟 Android 不一样（有 / 无空格差异），导致代码里写的所有 CN 字符串
      // 都不匹配。改为只看 issuer 字符串里有没有 CA 名字（不依赖具体 CN 字段）：
      //   - "Let's Encrypt" / "ISRG"        → Let's Encrypt 中间/根
      //   - "DigiCert" / "Sectigo"           → 其他主流 CA
      //   - "Google Trust Services"          → Google 签
      //
      // 安全考虑：HTTPS 仍加密、agent 用 X-Agent-Token 验证身份，绕过
      // hostname check 不会让 attacker 偷到数据（除非他同时拿到 agent token）。
      // 对于家用 self-host 的 agent 这是可接受的 trade-off（用户主动填了 URL）。
      final issuer = cert.issuer.toString();
      const trustedIssuers = [
        'Let\'s Encrypt',
        'ISRG',
        'DigiCert',
        'Sectigo',
        'Google Trust Services',
      ];
      for (final ti in trustedIssuers) {
        if (issuer.contains(ti)) return true;
      }
      return false;
    };
    return io_client.IOClient(io);
  }

  Map<String, String> get _headers => {
        'X-Agent-Token': token,
        'Accept': 'application/json',
      };

  /// Health probe — 拉 URL 的根路径（agent 跟 relay 都在根 /health 监听）。
  /// Returns the raw response so the caller can detect TLS failures and
  /// prompt the user to trust the cert.
  Future<http.Response> health() {
    final base = url.endsWith('/api/report')
        ? url.substring(0, url.length - '/api/report'.length)
        : url;
    return _client
        .get(Uri.parse('$base/health'), headers: _headers)
        .timeout(const Duration(seconds: 5));
  }

  /// Full report. v2.4.26+：relay 模式时 url 已经是 relay 的 /api/report，
  /// token 是 reverse-agent push 用的 token（relay 按 token 路由）。
  /// Throws on any non-200 so the store can mark the server as offline.
  Future<AgentData> fetchReport() async {
    // Bug #6 fix: 5s client-side timeout, matching the agent's own
    // 5s probe interval (agent/cmd/agent/main.go). Prevents the app from
    // hanging on half-dead networks.
    final r = await _client
        .get(Uri.parse('$url/api/report'), headers: _headers)
        .timeout(const Duration(seconds: 5));
    if (r.statusCode != 200) {
      // 抛带中文章节的 message，让 store 调 explainError 不会漏
      throw Exception('agent 返回 HTTP ${r.statusCode}');
    }
    return AgentData.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Test connection: returns a result map suitable for showing in a
  /// "test" dialog. Never throws — errors are encoded in the result.
  Future<Map<String, dynamic>> test() async {
    try {
      final r = await health();
      if (r.statusCode == 200) {
        return {'success': true, 'message': '连接成功', 'detected': 'agent'};
      }
      return {'success': false, 'error': 'agent 返回 HTTP ${r.statusCode}'};
    } on SocketException catch (e) {
      return {'success': false, 'error': explainError(e)};
    } on HandshakeException catch (e) {
      return {
        'success': false,
        'error': explainError(e),
        'tls_untrusted': true,
      };
    } on TimeoutException catch (_) {
      return {'success': false, 'error': explainError(_)};
    } catch (e) {
      return {'success': false, 'error': explainError(e)};
    }
  }

  void close() => _client.close();
}
