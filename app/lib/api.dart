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
  final String url;        // e.g. https://192.168.1.1:9101
  final String token;      // X-Agent-Token header value
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
      //    SAN entries. LE certs issued for an IP (e.g. /root/cert/ip/)
      //    chain to a system-trusted root but Dart still flags
      //    "Hostname mismatch". Since the user explicitly added this URL,
      //    we trust the cert as long as the issuer is a well-known CA.
      final issuer = cert.issuer.toString();
      const trustedIssuers = [
        'O = Let\'s Encrypt',
        'O = ISRG',
        'CN = R10', 'CN = R11', 'CN = R3', 'CN = E1', 'CN = E2', 'CN = R12',
        'CN = XR3', 'CN = XE1', 'CN = XE2', 'CN = X1', 'CN = X2',
        'CN = YE2', 'CN = YR1',
        'O = DigiCert', 'O = Sectigo', 'O = Google Trust Services',
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

  /// Health probe — just hits /health. Returns the raw response so the
  /// caller can detect TLS failures and prompt the user to trust the cert.
  Future<http.Response> health() {
    return _client
        .get(Uri.parse('$url/health'), headers: _headers)
        .timeout(const Duration(seconds: 5));
  }

  /// Full /api/report. Throws on any non-200 so the store can mark the
  /// server as offline.
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
