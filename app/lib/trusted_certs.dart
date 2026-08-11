// Trust-On-First-Use (TOFU) certificate pinning.
//
// When the app connects to an agent over HTTPS, the system trust store is
// consulted first (Let's Encrypt / DigiCert / etc. — works automatically).
// If verification fails (self-signed, internal CA, IP cert from an unknown
// CA), we *do not* silently accept — we surface a "trust this certificate?"
// dialog. If the user accepts, the SHA-256 fingerprint of the cert is
// stored locally and accepted for that exact URL on subsequent connects.
//
// Storage: SharedPreferences as a JSON map { "<url>": "<fingerprint>" }.

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TrustedCerts {
  static const _key = 'trusted_certs_v1';

  static Future<Map<String, String>> _load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  static Future<void> _save(Map<String, String> m) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(m));
  }

  /// SHA-256 fingerprint of the certificate's DER bytes, colon-separated
  /// upper-case hex (same format browsers show in the cert viewer).
  static String fingerprint(X509Certificate cert) {
    final digest = sha256.convert(cert.der);
    return digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .toList()
        .join(':');
  }

  static Future<bool> isTrusted(String url, String fingerprint) async {
    final m = await _load();
    final stored = m[url];
    return stored != null && stored == fingerprint;
  }

  /// v2.4.26+: 拿到所有信任的 cert（iOS 设置页显示数量用）
  static Future<Map<String, String>> all() async {
    return await _load();
  }

  static Future<void> trust(String url, String fingerprint) async {
    final m = await _load();
    m[url] = fingerprint;
    await _save(m);
    // Refresh any in-memory cache used by badCertificateCallback so the
    // trust takes effect on the very next poll (without waiting for an
    // app restart).
    await TrustedCertCache.refresh();
  }

  static Future<void> untrust(String url) async {
    final m = await _load();
    m.remove(url);
    await _save(m);
    await TrustedCertCache.refresh();
  }
}

/// In-memory mirror of [TrustedCerts]'s persisted fingerprints, so that
/// [HttpClient.badCertificateCallback] (which is sync) can answer without
/// awaiting SharedPreferences.
class TrustedCertCache {
  static Map<String, String> _map = {};
  static bool _loaded = false;

  static Future<void> refresh() async {
    _map = await TrustedCerts.all();
    _loaded = true;
  }

  static bool isTrusted(String url, X509Certificate cert) {
    if (!_loaded) return false; // wait for refresh() to populate
    final fp = TrustedCerts.fingerprint(cert);
    final stored = _map[url];
    return stored != null && stored == fp;
  }
}
