// iOS 风格添加服务器页

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../store.dart';
import '../errors.dart';
import 'ios_theme.dart';
import 'ios_glass.dart';

class IOSAddServerPage extends StatefulWidget {
  final MonitorStore store;
  const IOSAddServerPage({super.key, required this.store});

  @override
  State<IOSAddServerPage> createState() => _IOSAddServerPageState();
}

class _IOSAddServerPageState extends State<IOSAddServerPage> {
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    var url = _urlCtrl.text.trim();
    final token = _tokenCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入显示名称');
      return;
    }
    if (url.isEmpty) {
      setState(() => _error = '请输入 agent URL');
      return;
    }
    if (token.isEmpty) {
      setState(() => _error = '请输入 agent token');
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    if (!url.endsWith('/api/report')) {
      url = url.endsWith('/') ? '${url}api/report' : '$url/api/report';
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // 先 ping 一下确认能连
      await widget.store.testAgent(url: url, token: token);
      await widget.store.addAgentServer(name: name, url: url, token: token);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _error = explainError(e);
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: Colors.transparent,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: IOSTheme.glassDark,
        border: null,
        middle: const Text('添加服务器'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _saving ? null : _save,
          child: _saving
              ? const CupertinoActivityIndicator(radius: 10)
              : const Text('保存', style: TextStyle(color: IOSTheme.primary, fontWeight: FontWeight.w600)),
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(IOSTheme.paddingL),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('基本信息', style: TextStyle(color: IOSTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
              const SizedBox(height: 8),
              GlassContainer(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Column(
                  children: [
                    _field(_nameCtrl, '显示名称', hint: '例如：usvps'),
                    const Divider(color: IOSTheme.glassBorder, height: 1),
                    _field(_urlCtrl, 'Agent URL', hint: 'https://usvps.mzhhua.cn:9009', keyboardType: TextInputType.url),
                    const Divider(color: IOSTheme.glassBorder, height: 1),
                    _field(_tokenCtrl, 'Agent Token', hint: '32 字符随机', obscure: true),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: IOSTheme.danger.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(IOSTheme.radiusM),
                    border: Border.all(color: IOSTheme.danger.withOpacity(0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.exclamationmark_triangle, color: IOSTheme.danger, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_error!, style: const TextStyle(color: IOSTheme.danger, fontSize: 13))),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              const Text('说明', style: TextStyle(color: IOSTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
              const SizedBox(height: 8),
              Text(
                '• Token 跟 Android app 配的是同一个\n'
                '• 公网机器填 https://域名:端口/...（自签 cert 第一次会弹"信任"）\n'
                '• 内网机器用 reverse-agent 推给 relay，不需要在这加',
                style: TextStyle(color: IOSTheme.textTertiary, fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, {String? hint, TextInputType? keyboardType, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: CupertinoTextField(
              controller: ctrl,
              placeholder: hint,
              keyboardType: keyboardType,
              obscureText: obscure,
              style: const TextStyle(color: IOSTheme.textPrimary, fontSize: 15),
              placeholderStyle: const TextStyle(color: IOSTheme.textTertiary, fontSize: 14),
              decoration: const BoxDecoration(),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ],
      ),
    );
  }
}
