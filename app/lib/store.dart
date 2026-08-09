// Local state store. No backend — each MonitorServer keeps its own
// AgentClient and is polled directly. Server list (URL/name/disk-aliases)
// is persisted to SharedPreferences. Agent tokens are stored in
// flutter_secure_storage (Android Keystore-backed) so they survive
// uninstall/reinstall and stay encrypted at rest (v2.3.0).

import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'errors.dart';
import 'models.dart';

/// `context.monitor` — InheritedWidget sugar so widgets deep in the tree
/// can grab the [MonitorStore] without prop-drilling.
class _MonitorScope extends InheritedNotifier<MonitorStore> {
  const _MonitorScope({required MonitorStore super.notifier, required super.child});
}

class MonitorScope extends StatelessWidget {
  final MonitorStore store;
  final Widget child;
  const MonitorScope({super.key, required this.store, required this.child});

  @override
  Widget build(BuildContext context) {
    return _MonitorScope(notifier: store, child: child);
  }
}

extension MonitorScopeExt on BuildContext {
  MonitorStore get monitor {
    final inh = dependOnInheritedWidgetOfExactType<_MonitorScope>();
    assert(inh != null, 'MonitorScope not found — wrap with MonitorScope widget');
    return inh!.notifier!;
  }
}

class MonitorStore extends ChangeNotifier {
  static const _serversKey = 'monitor_servers_v2';
  // Bug #5: tokens now live in flutter_secure_storage (Android Keystore),
  // keyed by server id. Keeps tokens out of the plain JSON in SharedPreferences
  // and out of unencrypted backups.
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static String _tokenKey(String id) => 'token:$id';

  final Map<String, _PerServer> _perServer = {};
  List<MonitorServer> _servers = const [];
  MonitorServer? _currentServer;
  bool _isLoading = false;
  String? _error;
  /// True once [start] has finished loading persisted servers from disk.
  /// UI uses this to gate the first-launch AddServerDialog (so it doesn't
  /// pop up before SharedPreferences has been read).
  bool _firstLoadDone = false;
  bool get firstLoadDone => _firstLoadDone;

  /// The agent data currently being displayed for the current server.
  AgentData? get currentData {
    final s = _currentServer;
    if (s == null) return null;
    return _perServer[s.id]?.data;
  }

  /// Seconds since the current server last successfully responded.
  int? get currentSecondsAgo {
    final s = _currentServer;
    if (s == null) return null;
    final p = _perServer[s.id];
    if (p == null) return null;
    return ((DateTime.now().millisecondsSinceEpoch -
                p.lastSuccessMs) /1000).round();
  }

  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isOverview => _currentServer == null;
  MonitorServer? get currentServer => _currentServer;
  List<MonitorServer> get servers => List.unmodifiable(_servers);

  /// Aggregate per-server status for the overview page.
  Map<String, AgentData> get data {
    final out = <String, AgentData>{};
    for (final e in _perServer.entries) {
      final d = e.value.data;
      if (d != null) out[e.key] = d;
    }
    return out;
  }

  /// Servers in stable display order: user-added agent servers,
  /// ordered by sortOrder (then by name as tie-breaker). v2.1+ lets the
  /// user drag to reorder; the order is persisted via [reorder].
  List<MonitorServer> get orderedServers {
    final out = List<MonitorServer>.from(_servers);
    out.sort((a, b) {
      if (a.sortOrder != b.sortOrder) return a.sortOrder.compareTo(b.sortOrder);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  /// Get the latest data for a specific server (UI helper).
  AgentData? agentFor(MonitorServer s) => _perServer[s.id]?.data;

  /// Last error message for a specific server (UI helper).
  String? errorFor(MonitorServer s) => _perServer[s.id]?.lastError;

  /// Saved token for a server (UI helper, used by Edit dialog to know
  /// the *length*; the field is then cleared so the user must retype).
  String? tokenFor(String id) => _tokens[id];

  /// When did the last successful poll happen for this server?
  DateTime? lastSuccessFor(MonitorServer s) {
    final ms = _perServer[s.id]?.lastSuccessMs ?? 0;
    return ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Manually trigger a single poll for a specific server (UI refresh button).
  Future<void> pollServer(MonitorServer s) async {
    final p = _perServer[s.id];
    if (p == null) return;
    await p.pollOnce();
    notifyListeners();
  }

  /// When did the store last complete a successful poll of all servers?
  DateTime? get lastSuccessAt {
    int maxMs = 0;
    for (final p in _perServer.values) {
      if (p.lastSuccessMs > maxMs) maxMs = p.lastSuccessMs;
    }
    return maxMs == 0 ? null : DateTime.fromMillisecondsSinceEpoch(maxMs);
  }

  /// Per-disk UI config (aliases + hidden). v2.0.0 stores this locally
  /// on the device (no backend); v1 had it on the backend. v2.2.8 fix:
  /// actually persist the changes (was in-memory only, lost on restart).
  /// merge=true merges per-key into the existing map (used by the
  /// per-disk editor so editing one disk doesn't wipe the others).
  /// merge=false (default) replaces the maps entirely (used by the bulk
  /// manager so the user can delete an alias).
  ///
  /// Returns true if the write round-tripped through SharedPreferences
  /// (v2.4.4: post-save verify), false on mismatch (UI toasts on this).
  /// 改硬盘 alias / 隐藏状态。
  ///
  /// v2.4.14 简化：硬盘 alias 和隐藏**只维护在内存里，不落盘**。
  /// 之前的实现把整个 _servers 列表（包含 disk config）走 SharedPreferences
  /// 保存，问题：
  ///   1. 每次改一个盘要重新 encode 整个 server 列表
  ///   2. Android 上 Editor.commit() 偶尔返回 false → 整次保存失败
  ///   3. round-trip verify 反而引入假阳性（v2.4.13 撤了但没解决根本问题）
  ///
  /// 现在的实现：直接 in-memory 改 _servers 然后 notifyListeners()。
  /// 代价：app 重启后 alias / 隐藏会丢，需要重新设置。
  /// 收益：永远不会"保存失败"，逻辑也极简。
  /// 如果以后真要持久化，用 path_provider 写文件（更稳）或者独立 SharedPreferences
  /// key（不要嵌进 server 列表 JSON）。
  Future<bool> updateDiskConfig(
    String id, {
    Map<String, String>? aliases,
    Map<String, bool>? hidden,
    bool merge = false,
  }) async {
    final idx = _servers.indexWhere((s) => s.id == id);
    if (idx < 0) {
      return false;
    }
    final s = _servers[idx];
    final Map<String, String> newAliases = aliases == null
        ? s.diskAliases
        : (merge ? {...s.diskAliases, ...aliases} : aliases);
    final Map<String, bool> newHidden = hidden == null
        ? s.hiddenDisks
        : (merge ? {...s.hiddenDisks, ...hidden} : hidden);
    final updated = s.copyWith(
      diskAliases: newAliases,
      hiddenDisks: newHidden,
    );
    _servers = [..._servers]..[idx] = updated;
    if (_currentServer?.id == id) _currentServer = updated;
    notifyListeners();
    return true;
  }

  /// Initialize the store: load persisted servers, build clients, start
  /// polling. Call once on app start.
  Future<void> start() async {
    // Server list (URLs, names, disk aliases, …) is plain JSON in
    // SharedPreferences. Tokens are Keystore-backed via flutter_secure_storage.
    final saved = await _loadServers();
    // One-time migration: read legacy v2.2.x tokens from the JSON, push
    // them to secure storage, then strip them from the JSON. Idempotent.
    final legacy = await _extractLegacyTokens();
    for (final s in saved) {
      String? tok = await _secureStorage.read(key: _tokenKey(s.id));
      if ((tok == null || tok.isEmpty) && legacy.containsKey(s.id)) {
        tok = legacy[s.id];
        await _secureStorage.write(key: _tokenKey(s.id), value: tok);
      }
      _tokens[s.id] = tok ?? '';
      final p = _PerServer(
        server: s,
        client: (s.kind == 'agent' &&
                s.agentUrl != null &&
                tok != null &&
                tok.isNotEmpty)
            ? AgentClient(url: s.agentUrl!, token: tok)
            : null,
      );
      _perServer[s.id] = p;
    }
    if (legacy.isNotEmpty) {
      // Persist JSON without the legacy 'token' fields.
      await _saveServers(_servers);
    }
    _servers = saved;
    _firstLoadDone = true;
    notifyListeners();
    _tickAll();
    // Bug #6 fix: poll every 5s to match the agent's 5s probe interval.
    Timer.periodic(const Duration(seconds: 5), (_) => _tickAll());
  }

  void selectOverview() {
    if (_currentServer == null) return;
    _currentServer = null;
    notifyListeners();
  }

  void selectServer(MonitorServer s) {
    _currentServer = s;
    notifyListeners();
  }

  /// Add a new agent-mode server. Persists and starts polling immediately.
  Future<MonitorServer> addAgentServer({
    required String name,
    required String url,
    required String token,
  }) async {
    final uri = Uri.parse(url);
    final maxOrder = _servers.fold<int>(0, (m, s) => s.sortOrder > m ? s.sortOrder : m);
    final s = MonitorServer(
      id: _genId(name),
      name: name,
      host: uri.host,
      port: uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80),
      user: 'agent',
      kind: 'agent',
      https: uri.scheme == 'https',
      agentUrl: url,
      sortOrder: maxOrder + 1,
    );
    final p = _PerServer(server: s, client: AgentClient(url: url, token: token));
    _perServer[s.id] = p;
    _servers = [..._servers, s];
    _tokens[s.id] = token;
    await _secureStorage.write(key: _tokenKey(s.id), value: token);
    await _saveServers(_servers);
    notifyListeners();
    // Kick off an immediate probe so the user sees the result fast.
    unawaited(p.pollOnce());
    return s;
  }

  /// Update an existing server's connection info. The AgentClient is
  /// rebuilt with the new URL/token (and the trust cache is implicitly
  /// picked up on first poll).
  Future<void> updateServer({
    required String id,
    required String name,
    required String url,
    required String token,
  }) async {
    final idx = _servers.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final old = _servers[idx];
    final uri = Uri.parse(url);
    final updated = old.copyWith(
      name: name,
      host: uri.host,
      port: uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80),
      https: uri.scheme == 'https',
      agentUrl: url,
    );
    // Rebuild the client
    final oldP = _perServer.remove(id);
    oldP?.client?.close();
    final newP = _PerServer(
      server: updated,
      client: AgentClient(url: url, token: token),
    );
    _perServer[id] = newP;
    _servers = [..._servers]..[idx] = updated;
    if (_currentServer?.id == id) _currentServer = updated;
    _tokens[id] = token;
    await _secureStorage.write(key: _tokenKey(id), value: token);
    await _saveServers(_servers);
    notifyListeners();
    unawaited(newP.pollOnce());
  }

  /// Reorder the server list (called by ReorderableListView).
  Future<void> reorderServers(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _servers.length) return;
    if (newIndex > _servers.length) newIndex = _servers.length;
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    final list = List<MonitorServer>.from(_servers);
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    // Persist new order into sortOrder so it survives restarts.
    _servers = [
      for (int i = 0; i < list.length; i++) list[i].copyWith(sortOrder: i),
    ];
    notifyListeners();
    await _saveServers(_servers);
  }

  /// Delete a server. Stops polling and forgets credentials.
  Future<void> deleteServer(String id) async {
    final p = _perServer.remove(id);
    p?.client?.close();
    _tokens.remove(id);
    await _secureStorage.delete(key: _tokenKey(id));
    _servers = _servers.where((s) => s.id != id).toList();
    if (_currentServer?.id == id) _currentServer = null;
    await _saveServers(_servers);
    notifyListeners();
  }

  /// Test the connection for a would-be server. Returns a result map.
  /// Does NOT add the server; just probes.
  Future<Map<String, dynamic>> testAgent({
    required String url,
    required String token,
  }) async {
    final c = AgentClient(url: url, token: token);
    try {
      return await c.test();
    } finally {
      c.close();
    }
  }

  /// Trigger a manual poll of the current server (used by the "test" UI).
  Future<void> refreshCurrent() async {
    final s = _currentServer;
    if (s == null) return;
    final p = _perServer[s.id];
    if (p == null) return;
    await p.pollOnce();
    notifyListeners();
  }

  /// Retry every server. Useful for the "重试全部" button on the overview
  /// error view.
  Future<void> retryAll() async {
    _error = null;
    notifyListeners();
    for (final p in _perServer.values) {
      p.lastError = null;
    }
    await _tickAll();
  }

  Future<void> _tickAll() async {
    if (_isLoading) return;
    _isLoading = true;
    try {
      final futs = <Future<void>>[];
      for (final p in _perServer.values) {
        futs.add(p.pollOnce());
      }
      await Future.wait(futs, eagerError: false);
      // Aggregate any per-server errors so the UI can show them.
      final errs = <String>[];
      for (final p in _perServer.values) {
        if (p.lastError != null) errs.add('${p.server.name}: ${p.lastError}');
      }
      _error = errs.isEmpty ? null : errs.join('\n');
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // --- persistence ---

  /// In-memory cache of {serverId: token} for the UI helpers (e.g.
  /// [tokenFor]). Populated on [start] from secure storage; mutated
  /// alongside every add/update/delete.
  final Map<String, String> _tokens = {};

  /// One-shot migration helper: read v2.2.x-style JSON tokens from
  /// SharedPreferences (the old format stored tokens inline). Returns a
  /// map {serverId: token}; empty if no legacy entries exist or if the
  /// JSON can't be parsed.
  Future<Map<String, String>> _extractLegacyTokens() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_serversKey);
    if (raw == null || raw.isEmpty) return const {};
    final out = <String, String>{};
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final e in list) {
        final m = e as Map<String, dynamic>;
        if (m['token'] is String) {
          out[m['id'] as String] = m['token'] as String;
        }
      }
    } catch (_) {
      // Legacy JSON unreadable — start() will surface the parse error
      // through _loadServers() and reset to empty.
    }
    return out;
  }

  Future<List<MonitorServer>> _loadServers() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_serversKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => MonitorServer.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e, st) {
      // Bug #7 fix: surface the parse failure to the user (silent return
      // would lose all their server configs without warning). The error
      // banner on the overview page picks up `_error` and asks the user
      // to re-add servers.
      debugPrint('Failed to parse persisted server list: $e\n$st');
      _error = '本地服务器配置损坏或被外部修改，已重置为空白。请重新添加服务器。';
      // Bug fix: clear the "first launch already shown" flag so the
      // AddServerDialog auto-popup fires again on the next frame, instead
      // of dropping the user on an empty overview with no guidance.
      await p.remove('first_launch_shown');
      // Also nuke the corrupt bytes so we don't keep failing to parse them
      // on every subsequent launch.
      await p.remove(_serversKey);
      return const [];
    }
  }

  /// Returns true if SharedPreferences accepted the write. The plugin's
  /// setString uses Editor.commit() under the hood (synchronous on Android),
  /// so a successful return means the data is in the SharedPreferences
  /// in-memory cache + on disk — no need to re-read for verification.
  ///
  /// Bug fix: v2.4.4 added a "round-trip verify" by calling getString
  /// right after setString. On Android the in-memory cache is occasionally
  /// stale right after a write (plugin / platform-channel timing), causing
  /// getString to return the old value and the verify to fail with a false
  /// positive. The verify did more harm than good — it surfaced as
  /// "保存失败，详见 logcat" on every disk edit. Removed.
  Future<bool> _saveServers(List<MonitorServer> list) async {
    final p = await SharedPreferences.getInstance();
    final out = list.map((s) => s.toJson()).toList();
    final json = jsonEncode(out);
    try {
      final ok = await p.setString(_serversKey, json);
      if (!ok) {
        debugPrint('[MonitorStore] setString returned false for key=$_serversKey (${json.length} bytes)');
      }
      return ok;
    } catch (e, st) {
      debugPrint('[MonitorStore] setString threw: $e\n$st');
      return false;
    }
  }

  String _genId(String name) {
    final base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '-');
    final baseId = base.isEmpty
        ? 'srv-${DateTime.now().millisecondsSinceEpoch}'
        : base;
    // Bug #2 fix: detect name collisions and append a numeric suffix
    // (e.g. "my-server" → "my-server-2", "my-server-3"…).
    // Previously the second add silently overwrote the first server's
    // _perServer entry and token.
    if (!_idTaken(baseId)) return baseId;
    for (int i = 2; ; i++) {
      final candidate = '$baseId-$i';
      if (!_idTaken(candidate)) return candidate;
    }
  }

  /// True if [id] is already used by a registered server (either in
  /// the current list or in the in-memory polling map).
  bool _idTaken(String id) {
    if (_perServer.containsKey(id)) return true;
    for (final s in _servers) {
      if (s.id == id) return true;
    }
    return false;
  }
}

class _PerServer {
  final MonitorServer server;
  final AgentClient? client;
  AgentData? data;
  int lastSuccessMs = 0;
  String? lastError;

  _PerServer({required this.server, this.client});

  Future<void> pollOnce() async {
    final c = client;
    if (c == null) {
      lastError = '未配置 agent token';
      return;
    }
    try {
      data = await c.fetchReport();
      lastSuccessMs = DateTime.now().millisecondsSinceEpoch;
      lastError = null;
    } catch (e) {
      lastError = explainError(e);
    }
  }
}
