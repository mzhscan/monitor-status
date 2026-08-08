// 添加服务器对话框 —— v2.0.0 简化版
//
// 不再有 SSH/Agent 切换。所有被监控机器必须装 agent（由 install-agent.sh
// 一键部署），用户在 app 里填 agent 地址 + token。
//
// 包含：
//   - 名称（用户自定义）
//   - Agent 地址（https://host:port，agent 暴露的 URL）
//   - Agent Token（agent 启动时配置的 secret）
//   - 测试连接按钮：探测 + 处理自签证书首次信任弹窗
//   - 取消 / 添加 按钮

import 'dart:io';
import 'package:flutter/material.dart';
import 'api.dart';
import 'models.dart';
import 'store.dart';
import 'trusted_certs.dart';

class AddServerDialog extends StatefulWidget {
  final MonitorStore store;
  const AddServerDialog({super.key, required this.store});

  static Future<MonitorServer?> show(BuildContext context, MonitorStore store) {
    return showDialog<MonitorServer>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (ctx) => AddServerDialog(store: store),
    );
  }

  @override
  State<AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<AddServerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  bool _obscureToken = true;
  bool _busy = false;
  String? _testResult;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _doTest() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _testResult = null;
    });
    final url = _urlCtrl.text.trim();
    final token = _tokenCtrl.text;
    final res = await widget.store.testAgent(url: url, token: token);
    if (!mounted) return;

    if (res['tls_untrusted'] == true) {
      // Surface the cert's SHA-256 fingerprint and offer to trust it.
      final fp = await _captureCertFingerprint(url);
      if (!mounted) return;
      if (fp == null) {
        setState(() {
          _testResult = '[X] 探测到证书问题，但无法获取指纹';
          _busy = false;
        });
        return;
      }
      final accept = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('信任此证书？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '此服务器使用自签或不可信证书。\n'
                '请与服务器管理员确认以下指纹一致后再信任：',
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
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '指纹一致？点 "信任" 后保存到本机。',
                style: TextStyle(fontSize: 12, color: Color(0xFF7A7A82)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('信任'),
            ),
          ],
        ),
      );
      if (accept == true) {
        await TrustedCerts.trust(url, fp);
        // Refresh the in-memory cache that badCertificateCallback consults.
        // (We rebuild a fresh AgentClient below to pick up the change.)
        // Re-test now that the cert is trusted.
        final res2 = await widget.store.testAgent(url: url, token: token);
        if (!mounted) return;
        setState(() {
          _testResult = res2['success'] == true
              ? '[OK] 证书已信任，连接成功'
              : '[X] 仍无法连接：${res2['error']}';
          _busy = false;
        });
        return;
      }
      setState(() {
        _testResult = '[X] 证书未被信任';
        _busy = false;
      });
      return;
    }

    setState(() {
      _testResult = res['success'] == true
          ? '[OK] 连接成功'
          : '[X] ${res['error'] ?? '未知错误'}';
      _busy = false;
    });
  }

  /// Try to capture the cert fingerprint by making a raw socket connection.
  /// This bypasses the AgentClient's TOFU check so we can show the user
  /// what cert the server is presenting.
  Future<String?> _captureCertFingerprint(String url) async {
    try {
      final uri = Uri.parse(url);
      final sock = await SecureSocket.connect(
        uri.host,
        uri.port,
        timeout: const Duration(seconds: 5),
        onBadCertificate: (_) => true, // accept to peek
      );
      // Wait for handshake to complete then grab the peer cert.
      final cert = await sock.peerCertificate;
      sock.destroy();
      if (cert == null) return null;
      return TrustedCerts.fingerprint(cert);
    } catch (_) {
      return null;
    }
  }

  Future<void> _doAdd() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final s = await widget.store.addAgentServer(
        name: _nameCtrl.text.trim().isEmpty
            ? Uri.parse(_urlCtrl.text.trim()).host
            : _nameCtrl.text.trim(),
        url: _urlCtrl.text.trim(),
        token: _tokenCtrl.text,
      );
      if (mounted) Navigator.of(context).pop(s);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _testResult = '[X] 添加失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFFFFFFFF),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFFE5E5EA), width: 0.6),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: _title(),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '每台被监控的服务器都需要先安装 agent（一键脚本见 GitHub）。\n'
                  '填 agent 暴露的 HTTPS 地址 + token。',
                  style: TextStyle(color: Color(0xFF7A7A82), fontSize: 12),
                ),
                const SizedBox(height: 14),
                _label('显示名称'),
                _input(
                  controller: _nameCtrl,
                  hint: '例如：家里 NAS / 美国 VPS',
                  icon: Icons.bookmark_border_rounded,
                ),
                const SizedBox(height: 12),
                _label('Agent 地址（HTTPS）'),
                _input(
                  controller: _urlCtrl,
                  hint: 'https://server.example.com:9101',
                  icon: Icons.dns_rounded,
                  keyboardType: TextInputType.url,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return '必填';
                    final s = v.trim();
                    if (!s.startsWith('http://') && !s.startsWith('https://')) {
                      return '需要 http:// 或 https:// 开头';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                _label('Agent Token'),
                _input(
                  controller: _tokenCtrl,
                  hint: 'agent 启动时配置的密钥',
                  icon: Icons.key_rounded,
                  obscure: _obscureToken,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureToken
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      color: const Color(0xFF7A7A82),
                      size: 18,
                    ),
                    onPressed: () => setState(() => _obscureToken = !_obscureToken),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
                ),
                if (_testResult != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF0F5),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0x33FFB6C1)),
                    ),
                    child: Text(
                      _testResult!,
                      style: const TextStyle(
                        color: Color(0xFF2C2C2C),
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      actions: [
        TextButton(
          onPressed: _busy ? null : _doTest,
          style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF6B95)),
          child: const Text('测试连接'),
        ),
        FilledButton(
          onPressed: _busy ? null : _doAdd,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFFF6B95),
            disabledBackgroundColor: const Color(0xFFFFB6C1),
          ),
          child: _busy
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('添加'),
        ),
      ],
    );
  }

  Widget _title() {
    return Row(
      children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFFFFE4EC),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.add_rounded, color: Color(0xFFFF6B95), size: 20),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Text('添加服务器',
              style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A),
              )),
        ),
        InkWell(
          onTap: _busy ? null : () => Navigator.of(context).pop(),
          borderRadius: BorderRadius.circular(20),
          child: const Padding(
            padding: EdgeInsets.all(6),
            child: Icon(Icons.close_rounded, color: Color(0xFF7A7A82), size: 20),
          ),
        ),
      ],
    );
  }

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(s,
            style: const TextStyle(
                fontSize: 12, color: Color(0xFF7A7A82), fontWeight: FontWeight.w500)),
      );

  Widget _input({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      validator: validator,
      style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A1A)),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFFB5B5BD), fontSize: 13),
        prefixIcon: Icon(icon, color: const Color(0xFFFF6B95), size: 18),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: const Color(0xFFF7F7FA),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE5E5EA), width: 0.6),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFFF6B95), width: 1.2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE53935), width: 0.8),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE53935), width: 1.2),
        ),
      ),
    );
  }
}
