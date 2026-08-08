// Local state store. No backend — each MonitorServer keeps its own
// AgentClient and is polled directly. Server list is persisted to
// SharedPreferences so a user can uninstall/reinstall without losing
// their configs (caveat: agent token lives in plaintext on-device).

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
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

  final Map<String, _PerServer> _perServer = {};
  List<MonitorServer> _servers = const [];
  MonitorServer? _currentServer;
  bool _isLoading = false;
  String? _error;

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
  /// on the device (no backend); v1 had it on the backend. v2.0.0
  /// store keeps the API but the actual persistence is in-memory only
  /// (lost on app restart). Add local disk-config persistence in v2.1.
  Future<void> updateDiskConfig(
    String id, {
    Map<String, String>? aliases,
    Map<String, bool>? hidden,
  }) async {
    final s = _servers.firstWhere(
      (s) => s.id == id,
      orElse: () => _servers.first,
    );
    final updated = s.copyWith(
      diskAliases: aliases ?? s.diskAliases,
      hiddenDisks: hidden ?? s.hiddenDisks,
    );
    _servers = _servers.map((x) => x.id == id ? updated : x).toList();
    if (_currentServer?.id == id) _currentServer = updated;
    notifyListeners();
  }

  /// Initialize the store: load persisted servers, build clients, start
  /// polling. Call once on app start.
  Future<void> start() async {
    final saved = await _loadServers();
    for (final s in saved) {
      final tok = _tokens[s.id];
      final p = _PerServer(
        server: s,
        client: (s.kind == 'agent' && s.agentUrl != null && tok != null)
            ? AgentClient(url: s.agentUrl!, token: tok)
            : null,
      );
      _perServer[s.id] = p;
    }
    _servers = saved;
    notifyListeners();
    _tickAll();
    Timer.periodic(const Duration(seconds: 2), (_) => _tickAll());
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
    await _saveServers(_servers, token: token);
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
    await _saveServers(_servers, token: token);
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

  /// In-memory cache of {serverId: token} (plaintext — see v2.1 todo).
  final Map<String, String> _tokens = {};

  Future<List<MonitorServer>> _loadServers() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_serversKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final e in list) {
        final m = e as Map<String, dynamic>;
        if (m['token'] is String) {
          _tokens[m['id'] as String] = m['token'] as String;
        }
      }
      return list
          .map((e) => MonitorServer.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveServers(List<MonitorServer> list, {String? token}) async {
    final p = await SharedPreferences.getInstance();
    final out = <Map<String, dynamic>>[];
    for (final s in list) {
      final j = s.toJson();
      // Persist the latest token alongside the server entry.
      final tok = token ?? _tokens[s.id];
      if (tok != null) j['token'] = tok;
      out.add(j);
    }
    await p.setString(_serversKey, jsonEncode(out));
  }

  String _genId(String name) {
    final cleaned = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '-');
    if (cleaned.isEmpty) {
      return 'srv-${DateTime.now().millisecondsSinceEpoch}';
    }
    return cleaned;
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
