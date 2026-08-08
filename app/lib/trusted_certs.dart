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

  static Future<void> trust(String url, String fingerprint) async {
    final m = await _load();
    m[url] = fingerprint;
    await _save(m);
  }

  static Future<void> untrust(String url) async {
    final m = await _load();
    m.remove(url);
    await _save(m);
  }

  static Future<Map<String, String>> all() => _load();
}
