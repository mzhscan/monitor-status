// GitHub release 检查 + 打开 release 页面 / README 链接
//
// 注意：const String.fromEnvironment 用于 build 时的硬编码值。这里
// APP_VERSION 来自 pubspec.yaml，pub_get 时已注入。

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class CheckUpdate {
  /// 当前版本（pubspec.yaml 里的 version 字段）
  static const String currentVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '2.0.0',
  );

  /// 当前 build number
  static const String currentBuild = String.fromEnvironment(
    'APP_BUILD',
    defaultValue: '20',
  );

  /// GitHub 仓库（owner/name）—— v2.0.0 之后写死
  /// 若要换仓库，所有已装 APK 需要重新 build（这就是为啥写死而不是 --dart-define）
  static const String repo = 'mzhscan/monitor-status';

  static String get _apiUrl => 'https://api.github.com/repos/$repo/releases/latest';
  static String get _releasePage => 'https://github.com/$repo/releases/latest';
  static String get _readmeUrl => 'https://github.com/$repo#readme';

  /// Fetch the latest release. Returns null on network / parse error.
  static Future<CheckUpdateResult> fetchLatest() async {
    try {
      final r = await http
          .get(Uri.parse(_apiUrl), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        return CheckUpdateResult.error('GitHub 返回 HTTP ${r.statusCode}');
      }
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final tag = (j['tag_name'] as String?) ?? '';
      final body = (j['body'] as String?) ?? '';
      // Strip leading "v" if present, then semver-compare
      final remote = _parseSemver(tag);
      final local = _parseSemver(currentVersion);
      final isNewer = remote != null && local != null && _compare(remote, local) > 0;
      return CheckUpdateResult(
        latestTag: tag,
        body: body,
        isNewer: isNewer,
      );
    } catch (e) {
      return CheckUpdateResult.error(e.toString());
    }
  }

  static List<int>? _parseSemver(String s) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(s.trim());
    if (m == null) return null;
    return [int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)];
  }

  /// Returns positive if a > b.
  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return 0;
  }

  static Future<void> openReleasePage(BuildContext context) async {
    final uri = Uri.parse(_releasePage);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  static Future<void> openReadme(BuildContext context) async {
    final uri = Uri.parse(_readmeUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

class CheckUpdateResult {
  final String? latestTag;
  final String? body;
  final bool isNewer;
  final bool isError;
  final String? error;

  const CheckUpdateResult({
    this.latestTag,
    this.body,
    this.isNewer = false,
    this.isError = false,
    this.error,
  });

  factory CheckUpdateResult.error(String msg) =>
      CheckUpdateResult(isError: true, error: msg);

  String get summary {
    if (isError) return '检查失败：$error';
    if (latestTag == null || latestTag!.isEmpty) return '无 release 信息';
    if (isNewer) return '有新版本: v$latestTag';
    return '当前已是最新版本 (v$latestTag)';
  }
}
