// iOS 27 风格添加 / 编辑服务器页
//
// 跟安卓版 add_server_dialog 对齐：
//   - 5 字段（name / host / port / https 切换 / token）
//   - URL 实时预览
//   - 测试连接按钮 + 测试结果
//   - TOFU 自签证书信任弹框
//   - 编辑模式：initial 非空时为编辑，保留旧 token（obscure 默认）
//   - 新增模式：token 必填

import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../errors.dart';
import '../models.dart';
import '../store.dart';
import '../trusted_certs.dart';
import 'ios_theme.dart';
import 'ios_glass.dart';

/// 写一行日志到 app 文档目录的 debug.log。release 模式 devicectl --console
/// 抓不到 debugPrint（Flutter dart:io print 走 OSLog），但写到文件就能
/// 之后从 host 用 `xcrun devicectl device file copy` 拉出来看。
Future<void> _debugLog(String msg) async {
  debugPrint('[DEBUG] $msg');
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/debug.log');
    final ts = DateTime.now().toIso8601String();
    await f.writeAsString('$ts $msg\n',
        mode: FileMode.append, flush: true);
  } catch (_) {}
}

class IOSAddServerPage extends StatefulWidget {
  final MonitorStore store;
  final MonitorServer? initial;  // 非空 = 编辑模式
  // 关闭回调：保存/取消时触发，父（IOSApp）用来切回 _currentIndex=0/1
  // —— 修添加 tab 切换动画问题：现在 add page 走 IndexedStack[2] 不再 push，
  // 用 callback 通知父切 tab，不要用 Navigator.pop
  final VoidCallback? onClose;
  const IOSAddServerPage({super.key, required this.store, this.initial, this.onClose});

  @override
  State<IOSAddServerPage> createState() => _IOSAddServerPageState();
}

class _IOSAddServerPageState extends State<IOSAddServerPage> {
  late final _nameCtrl = TextEditingController(text: widget.initial?.name ?? '');
  late final _hostCtrl = TextEditingController(text: widget.initial?.host ?? '');
  late final _portCtrl = TextEditingController(
      text: widget.initial != null ? widget.initial!.port.toString() : '');
  late final _tokenCtrl = TextEditingController(
      text: widget.store.tokenFor(widget.initial?.id ?? '') ?? '');
  late bool _https = widget.initial?.https ?? true;
  bool _obscureToken = true;
  bool _busy = false;
  String? _testResult;
  bool _testOk = false;

  bool get _isEdit => widget.initial != null;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  String get _fullUrl {
    final host = _hostCtrl.text.trim();
    final port = _portCtrl.text.trim();
    final scheme = _https ? 'https' : 'http';
    if (host.isEmpty) return '$scheme://（域名/IP）:${port.isEmpty ? "端口" : port}';
    return '$scheme://$host:${port.isEmpty ? "?" : port}';
  }

  Future<void> _doTest() async {
    final host = _hostCtrl.text.trim();
    final portStr = _portCtrl.text.trim();
    if (host.isEmpty) {
      setState(() {
        _testResult = '请先填域名或 IP';
        _testOk = false;
      });
      return;
    }
    final port = int.tryParse(portStr);
    if (port == null) {
      setState(() {
        _testResult = '端口必须是数字';
        _testOk = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _testResult = null;
      _testOk = false;
    });
    final scheme = _https ? 'https' : 'http';
    final url = '$scheme://$host:$port';
    final token = _tokenCtrl.text.isNotEmpty
        ? _tokenCtrl.text
        : (widget.store.tokenFor(widget.initial?.id ?? '') ?? '');
    if (token.isEmpty) {
      setState(() {
        _testResult = '请先填 Agent Token';
        _testOk = false;
        _busy = false;
      });
      return;
    }
    debugPrint('[DEBUG] testAgent url=$url token.len=${token.length}');
    _debugLog('testAgent url=$url token.len=${token.length}');
    Map<String, dynamic> res;
    try {
      res = await widget.store.testAgent(url: url, token: token);
      debugPrint('[DEBUG] testAgent result=$res');
      _debugLog('testAgent result=$res');
    } catch (e, st) {
      debugPrint('[DEBUG] testAgent EXCEPTION: $e\n$st');
      _debugLog('testAgent EXCEPTION: ${e.runtimeType}: $e\n$st');
      if (!mounted) return;
      setState(() {
        _testResult = '❌ 异常：${e.runtimeType}: $e';
        _busy = false;
      });
      return;
    }
    if (!mounted) return;

    if (res['tls_untrusted'] == true) {
      final fp = await _captureCertFingerprint(url);
      if (!mounted) return;
      if (fp == null) {
        setState(() {
          _testResult = '网络异常，无法获取证书指纹。请检查网络后重新点"测试连接"。';
          _busy = false;
        });
        return;
      }
      final accept = await _showTrustDialog(fp);
      if (!mounted) return;
      if (accept == true) {
        await TrustedCerts.trust(url, fp);
        await TrustedCertCache.refresh();
        final res2 = await widget.store.testAgent(url: url, token: token);
        if (!mounted) return;
        setState(() {
          _testOk = res2['success'] == true;
          _testResult = res2['success'] == true
              ? '✅ 证书已信任，连接成功'
              : '❌ ${res2['error'] ?? "仍无法连接"}';
          _busy = false;
        });
        return;
      }
      setState(() {
        _testResult = '❌ 证书未被信任';
        _busy = false;
      });
      return;
    }

    setState(() {
      _testOk = res['success'] == true;
      _testResult = res['success'] == true
          ? '✅ 连接成功'
          : '❌ ${res['error'] ?? "未知错误"}';
      _busy = false;
    });
  }

  Future<String?> _captureCertFingerprint(String url) async {
    try {
      final uri = Uri.parse(url);
      debugPrint('[DEBUG] captureCertFingerprint uri=$uri');
      _debugLog('captureCertFingerprint uri=$uri');
      final sock = await SecureSocket.connect(
        uri.host,
        uri.port,
        timeout: const Duration(seconds: 5),
        onBadCertificate: (_) => true,
      );
      debugPrint('[DEBUG] SecureSocket.connect ok, peerCert=${sock.peerCertificate != null}');
      _debugLog('SecureSocket.connect ok, peerCert=${sock.peerCertificate != null}');
      final cert = sock.peerCertificate;
      sock.destroy();
      if (cert == null) return null;
      // 用与 TrustedCerts.fingerprint 一致的 SHA-256 DER
      final digest = sha256.convert(cert.der);
      return digest.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .toList()
          .join(':');
    } catch (e, st) {
      debugPrint('[DEBUG] captureCertFingerprint EXCEPTION: ${e.runtimeType}: $e\n$st');
      _debugLog('captureCertFingerprint EXCEPTION: ${e.runtimeType}: $e\n$st');
      return null;
    }
  }

  Future<bool?> _showTrustDialog(String fp) {
    return showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('信任此证书？'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '此服务器使用自签或不可信证书。\n请与服务器管理员确认以下指纹一致后再信任：',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  fp,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '指纹一致？点 "信任" 后保存到本机。',
                style: TextStyle(fontSize: 12, color: Color(0xFF7A7A82)),
              ),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('信任'),
          ),
        ],
      ),
    );
  }

  Future<void> _doSave() async {
    final host = _hostCtrl.text.trim();
    final portStr = _portCtrl.text.trim();
    if (host.isEmpty) {
      setState(() => _testResult = '❌ 请填域名或 IP');
      return;
    }
    final port = int.tryParse(portStr);
    if (port == null) {
      setState(() => _testResult = '❌ 端口必须是数字');
      return;
    }
    final token = _tokenCtrl.text.isNotEmpty
        ? _tokenCtrl.text
        : (widget.store.tokenFor(widget.initial?.id ?? '') ?? '');
    final hasOld = _isEdit && (widget.store.tokenFor(widget.initial!.id) ?? '').isNotEmpty;
    if (token.isEmpty && !hasOld) {
      setState(() => _testResult = '❌ 请填 Agent Token');
      return;
    }
    setState(() => _busy = true);
    try {
      final scheme = _https ? 'https' : 'http';
      final url = '$scheme://$host:$port';
      final name = _nameCtrl.text.trim().isEmpty ? host : _nameCtrl.text.trim();
      if (_isEdit) {
        await widget.store.updateServer(
          id: widget.initial!.id,
          name: name,
          url: url,
          token: token,
        );
        if (mounted) widget.onClose?.call();
      } else {
        await widget.store.addAgentServer(name: name, url: url, token: token);
        if (mounted) widget.onClose?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _testResult = '❌ 保存失败：${explainError(e)}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      // 修添加 tab 切换动画：现在 add page 走 IndexedStack[2]（不是 push modal），
      // 跟机器/设置 tab 一样瞬间切换，不再 fullscreenDialog 从下滑入
      backgroundColor: const Color(0xFFFFFFFF),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: IOSTheme.glassDark,
        border: null,
        // 取消：通知父切回原 tab（不是 Navigator.pop，因为 add page 走 IndexedStack）
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _busy ? null : () => widget.onClose?.call(),
          child: const Text('取消', style: TextStyle(color: IOSTheme.primary)),
        ),
        middle: Text(_isEdit ? '编辑服务器' : '添加服务器'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _busy ? null : _doSave,
          child: _busy
              ? const CupertinoActivityIndicator(radius: 10)
              : Text(
                  _isEdit ? '保存' : '添加',
                  style: const TextStyle(
                      color: IOSTheme.primary, fontWeight: FontWeight.w600),
                ),
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(IOSTheme.paddingL),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 14),
              const Text(
                '每台被监控的服务器都需要先安装 agent（一键脚本见 GitHub）。\n填 agent 暴露的域名/IP + 端口 + 协议 + token。\n内网机器：填公网 relay 的域名/端口 + reverse-agent push 用的 token。',
                style: TextStyle(color: IOSTheme.textTertiary, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 14),
              GlassContainer(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Column(
                  children: [
                    _field(_nameCtrl, '显示名称', hint: '例如：家里 NAS / 美国 VPS'),
                    const Divider(color: IOSTheme.glassBorder, height: 1),
                    _field(_hostCtrl, '域名或 IP',
                        hint: 'agent.example.com 或 192.0.2.1',
                        keyboardType: TextInputType.url),
                    const Divider(color: IOSTheme.glassBorder, height: 1),
                    Row(
                      children: [
                        Expanded(
                          child: _field(_portCtrl, '端口',
                              hint: '例如 9009',
                              keyboardType: TextInputType.number),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: _httpsToggle()),
                      ],
                    ),
                    const Divider(color: IOSTheme.glassBorder, height: 1),
                    _field(_tokenCtrl, 'Agent Token',
                        hint: 'agent 启动时配置的密钥',
                        obscure: _obscureToken,
                        suffix: CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: () =>
                              setState(() => _obscureToken = !_obscureToken),
                          child: Icon(
                            _obscureToken
                                ? CupertinoIcons.eye
                                : CupertinoIcons.eye_slash,
                            color: IOSTheme.textTertiary,
                            size: 18,
                          ),
                        )),
                  ],
                ),
              ),
              // 实时 URL 预览
              const SizedBox(height: 10),
              AnimatedBuilder(
                animation: Listenable.merge([_hostCtrl, _portCtrl]),
                builder: (context, _) => Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: IOSTheme.glassDark,
                    borderRadius: BorderRadius.circular(IOSTheme.radiusS),
                    border: Border.all(color: IOSTheme.glassBorder, width: 0.5),
                  ),
                  child: Text(
                    '实际地址：$_fullUrl',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: IOSTheme.textSecondary,
                    ),
                  ),
                ),
              ),
              if (_testResult != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _testOk
                        ? IOSTheme.success.withOpacity(0.12)
                        : IOSTheme.danger.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(IOSTheme.radiusS),
                    border: Border.all(
                      color: _testOk
                          ? IOSTheme.success.withOpacity(0.4)
                          : IOSTheme.danger.withOpacity(0.4),
                    ),
                  ),
                  child: Text(
                    _testResult!,
                    style: TextStyle(
                      color: _testOk ? IOSTheme.success : IOSTheme.textPrimary,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              // 测试按钮
              SizedBox(
                width: double.infinity,
                child: GlassPill(
                  onTap: _busy ? null : _doTest,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _busy
                      ? const CupertinoActivityIndicator()
                      : const Text(
                          '测试连接',
                          style: TextStyle(
                            color: IOSTheme.primary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('说明', style: TextStyle(color: IOSTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
              const SizedBox(height: 8),
              const Text(
                '• Token 跟 Android app 配的是同一个\n'
                '• 公网机器填 https://域名:端口（自签 cert 第一次会弹"信任"）\n'
                '• 内网机器用 reverse-agent 推给 relay，不需要在这加',
                style: TextStyle(color: IOSTheme.textTertiary, fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    String? hint,
    TextInputType? keyboardType,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: const TextStyle(
                    color: IOSTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: CupertinoTextField(
              controller: ctrl,
              placeholder: hint,
              keyboardType: keyboardType,
              obscureText: obscure,
              style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 15),
              placeholderStyle:
                  const TextStyle(color: IOSTheme.textTertiary, fontSize: 14),
              decoration: const BoxDecoration(),
              padding: const EdgeInsets.symmetric(vertical: 12),
              suffix: suffix == null
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: suffix,
                    ),
              suffixMode: suffix == null
                  ? OverlayVisibilityMode.never
                  : OverlayVisibilityMode.always,
            ),
          ),
        ],
      ),
    );
  }

  Widget _httpsToggle() {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: IOSTheme.glassDark,
        borderRadius: BorderRadius.circular(IOSTheme.radiusS),
        border: Border.all(color: IOSTheme.glassBorder, width: 0.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _https = true),
              child: Container(
                decoration: BoxDecoration(
                  color: _https ? IOSTheme.primary : Colors.transparent,
                  borderRadius:
                      const BorderRadius.horizontal(left: Radius.circular(13)),
                ),
                alignment: Alignment.center,
                child: Text(
                  'HTTPS',
                  style: TextStyle(
                    color: _https ? Colors.white : IOSTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _https = false),
              child: Container(
                decoration: BoxDecoration(
                  color: !_https ? IOSTheme.primary : Colors.transparent,
                  borderRadius:
                      const BorderRadius.horizontal(right: Radius.circular(13)),
                ),
                alignment: Alignment.center,
                child: Text(
                  'HTTP',
                  style: TextStyle(
                    color: !_https ? Colors.white : IOSTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
