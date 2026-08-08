// Data models matching the Go backend's JSON response.
//
// All numeric fields come back as JSON numbers — Dart's jsonDecode gives them
// as either int or double depending on size. We normalize via .toDouble() /
// .toInt() to keep things predictable.

double _d(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
int _i(dynamic v) => (v as num?)?.toInt() ?? 0;
bool _b(dynamic v) => v == true;
String _s(dynamic v) => (v as String?) ?? '';


class CpuInfo {
  final String model;
  final int cores;
  final double percent;
  final double tempC;
  const CpuInfo({
    this.model = '',
    this.cores = 0,
    required this.percent,
    required this.tempC,
  });
  factory CpuInfo.fromJson(Map<String, dynamic> j) => CpuInfo(
        model: _s(j['model']),
        cores: _i(j['cores']),
        percent: _d(j['usage']) > 0 ? _d(j['usage']) : _d(j['percent']),
        tempC: _d(j['temp_c']),
      );
  bool get hasTemp => tempC > 0;
  bool get hasModel => model.isNotEmpty;
}

class MemoryInfo {
  final double percent;
  final double usedMb;
  final double totalMb;
  final double usedGb;
  final double totalGb;
  const MemoryInfo({
    required this.percent,
    required this.usedMb,
    required this.totalMb,
    required this.usedGb,
    required this.totalGb,
  });
  factory MemoryInfo.fromJson(Map<String, dynamic> j) {
    // Two shapes are supported:
    //   - new (bytes): { percent, total, used }
    //   - legacy:      { percent, used_mb, total_mb }
    final usedMbRaw = _d(j['used_mb']);
    final totalMbRaw = _d(j['total_mb']);
    double usedMb, totalMb;
    if (usedMbRaw > 0 || totalMbRaw > 0) {
      usedMb = usedMbRaw;
      totalMb = totalMbRaw;
    } else {
      usedMb = _d(j['used']) / (1024 * 1024);
      totalMb = _d(j['total']) / (1024 * 1024);
    }
    return MemoryInfo(
      percent: _d(j['percent']),
      usedMb: usedMb,
      totalMb: totalMb,
      usedGb: usedMb / 1024,
      totalGb: totalMb / 1024,
    );
  }
}

class DiskEntry {
  final String name;     // human label (label if available, else mount)
  final String mount;
  final String device;
  final double usedGb;
  final double totalGb;
  final double availGb;
  final double percent;
  final double? tempC;
  const DiskEntry({
    this.name = '',
    required this.mount,
    this.device = '',
    required this.usedGb,
    required this.totalGb,
    required this.availGb,
    required this.percent,
    this.tempC,
  });
  factory DiskEntry.fromJson(Map<String, dynamic> j) {
    // Two shapes are supported:
    //   - bytes: { size, used }  (new collector / hardware.go)
    //   - GB:    { total_gb, used_gb }  (legacy agent / some paths)
    double sizeBytes = _d(j['size']);
    double usedBytes = _d(j['used']);
    if (sizeBytes <= 0) sizeBytes = _d(j['total_gb']) * 1024 * 1024 * 1024;
    if (usedBytes <= 0) usedBytes = _d(j['used_gb']) * 1024 * 1024 * 1024;
    final totalGb = sizeBytes / (1024 * 1024 * 1024);
    final usedGb = usedBytes / (1024 * 1024 * 1024);
    // If percent is missing, derive it.
    double pct = _d(j['percent']);
    if (pct <= 0 && sizeBytes > 0) {
      pct = usedBytes * 100 / sizeBytes;
    }
    return DiskEntry(
      name: _s(j['name']),
      mount: _s(j['mount']),
      device: _s(j['device']),
      usedGb: usedGb,
      totalGb: totalGb,
      availGb: totalGb - usedGb,
      percent: pct,
      tempC: (j['temp_c'] as num?)?.toDouble(),
    );
  }
  bool get hasTemp => tempC != null && tempC! > 0;
}

class GpuInfo {
  final String? model;
  final double? percent;
  final double? tempC;
  final double? usedMb;
  final double? totalMb;
  const GpuInfo({this.model, this.percent, this.tempC, this.usedMb, this.totalMb});

  /// Try several field names for VRAM. Suffix convention:
  ///   *_mb   → value is in MB
  ///   *_bytes / no suffix → value is in bytes
  static double? _vramFromJson(Map<String, dynamic> j, bool isTotal) {
    final mbKeys = isTotal
        ? const ['total_mb', 'memory_total_mb', 'vram_total_mb', 'mem_total_mb', 'memory_mb', 'vram_mb']
        : const ['used_mb', 'memory_used_mb', 'vram_used_mb', 'mem_used_mb', 'memory_mb_used', 'vram_mb_used'];
    for (final k in mbKeys) {
      final v = j[k];
      if (v is num && v > 0) return v.toDouble();
    }
    final bytesKeys = isTotal
        ? const ['mem_total', 'memory_total', 'vram_total', 'gpu_mem_total', 'total_bytes', 'memory_total_bytes', 'vram_total_bytes']
        : const ['mem_used', 'memory_used', 'vram_used', 'gpu_mem_used', 'used_bytes', 'memory_used_bytes', 'vram_used_bytes'];
    for (final k in bytesKeys) {
      final v = j[k];
      if (v is num && v > 0) return v.toDouble() / (1024 * 1024);
    }
    // NVIDIA-smi style: derive used = total - free
    if (!isTotal) {
      final total = _vramFromJson(j, true);
      final free = j['mem_free'] ?? j['memory_free'] ?? j['vram_free'];
      if (total != null && free is num && free >= 0) {
        return (total - free / (1024 * 1024)).clamp(0, total);
      }
    }
    return null;
  }

  factory GpuInfo.fromJson(Map<String, dynamic> j) => GpuInfo(
        model: j['model'] as String?,
        percent: (j['util'] as num?)?.toDouble() ?? (j['percent'] as num?)?.toDouble(),
        tempC: (j['temp_c'] as num?)?.toDouble(),
        usedMb: _vramFromJson(j, false),
        totalMb: _vramFromJson(j, true),
      );
  bool get hasUtil => percent != null;
  bool get hasTemp => tempC != null && tempC! > 0;
  bool get hasMemory => usedMb != null && totalMb != null;
  bool get available => true;
}

class LoadInfo {
  final double l1, l5, l15;
  const LoadInfo({required this.l1, required this.l5, required this.l15});
  factory LoadInfo.fromJson(Map<String, dynamic> j) => LoadInfo(
        l1: _d(j['1min']),
        l5: _d(j['5min']),
        l15: _d(j['15min']),
      );
}

class NetworkInfo {
  final int rxBytes;
  final int txBytes;
  final double rxMb;
  final double txMb;
  const NetworkInfo({
    required this.rxBytes,
    required this.txBytes,
    required this.rxMb,
    required this.txMb,
  });
  factory NetworkInfo.fromJson(Map<String, dynamic> j) {
    // Try multiple field-name variants for bytes (different agents/SSH collectors
    // name things differently — rx_bytes / bytes_in / in, tx_bytes / bytes_out / out).
    int pickInt(List<String> keys) {
      for (final k in keys) {
        final v = _i(j[k]);
        if (v != 0) return v;
      }
      return 0;
    }
    final rxBytes = pickInt([
      'rx_bytes', 'bytes_in', 'bytes_recv', 'in', 'download',
      'received_bytes', 'recv_bytes', 'net_rx', 'network_rx', 'rx',
    ]);
    final txBytes = pickInt([
      'tx_bytes', 'bytes_out', 'bytes_sent', 'out', 'upload',
      'sent_bytes', 'net_tx', 'network_tx', 'tx',
    ]);
    // Prefer explicit _mb fields; fall back to computing from bytes when missing/zero.
    double rxMb = _d(j['rx_mb']);
    double txMb = _d(j['tx_mb']);
    if (rxMb <= 0 && rxBytes > 0) rxMb = rxBytes / (1024 * 1024);
    if (txMb <= 0 && txBytes > 0) txMb = txBytes / (1024 * 1024);
    return NetworkInfo(
      rxBytes: rxBytes,
      txBytes: txBytes,
      rxMb: rxMb,
      txMb: txMb,
    );
  }
}

class DiskInfo {
  final double percent;
  final double usedGb;
  final double totalGb;
  const DiskInfo({required this.percent, required this.usedGb, required this.totalGb});
  factory DiskInfo.fromJson(Map<String, dynamic> j) => DiskInfo(
        percent: _d(j['percent']),
        usedGb: _d(j['used_gb']),
        totalGb: _d(j['total_gb']),
      );
}

class Hardware {
  final CpuInfo? cpu;
  final MemoryInfo? memory;
  final GpuInfo? gpu;
  final DiskInfo? disk;
  final List<DiskEntry>? disks;
  final LoadInfo? load;
  final NetworkInfo? network;
  final String uptime;
  const Hardware({
    this.cpu,
    this.memory,
    this.gpu,
    this.disk,
    this.disks,
    this.load,
    this.network,
    required this.uptime,
  });
  factory Hardware.fromJson(Map<String, dynamic> j) {
    // New backend shape uses bytes for mem/disk; legacy uses _mb/_gb.
    final memoryJson = j['memory'] as Map<String, dynamic>?;
    final hasLegacyMem = memoryJson != null &&
        (memoryJson.containsKey('used_mb') || memoryJson.containsKey('used_gb'));
    final disksJson = j['disks'] as List?;
    // Network may be under several keys depending on the agent.
    final networkJson = (j['network'] ?? j['net'] ?? j['net_io'] ?? j['netio'] ?? j['bandwidth'])
        is Map
        ? ((j['network'] ?? j['net'] ?? j['net_io'] ?? j['netio'] ?? j['bandwidth'])
            as Map<String, dynamic>)
        : null;
    return Hardware(
      cpu: j['cpu'] is Map ? CpuInfo.fromJson(j['cpu']) : null,
      memory: memoryJson == null
          ? null
          : hasLegacyMem
              ? MemoryInfo.fromJson({
                  'percent': memoryJson['percent'],
                  'used_mb': memoryJson['used_mb'] ?? _d(memoryJson['used_gb']) * 1024,
                  'total_mb': memoryJson['total_mb'] ?? _d(memoryJson['total_gb']) * 1024,
                })
              : MemoryInfo.fromJson(memoryJson),
      gpu: j['gpu'] is Map ? GpuInfo.fromJson(j['gpu']) : null,
      disk: j['disk'] is Map ? DiskInfo.fromJson(j['disk']) : null,
      disks: disksJson
          ?.map((e) {
            final m = e as Map<String, dynamic>;
            if (m.containsKey('used_gb')) {
              return DiskEntry.fromJson(m);
            }
            return DiskEntry.fromJson(m);
          })
          .toList(),
      load: j['load'] is Map ? LoadInfo.fromJson(j['load']) : null,
      network: networkJson == null ? null : NetworkInfo.fromJson(networkJson),
      uptime: _s(j['uptime']),
    );
  }
}

class XuiClient {
  final String email;
  final bool online;
  final bool enable;
  final int upBytes;
  final int downBytes;
  final double upMb;
  final double downMb;
  final double upGb;
  final double downGb;
  final int lastOnline; // unix ms
  final double? traffic72hGb; // optional, depends on backend
  const XuiClient({
    required this.email,
    required this.online,
    required this.enable,
    required this.upBytes,
    required this.downBytes,
    required this.upMb,
    required this.downMb,
    required this.upGb,
    required this.downGb,
    required this.lastOnline,
    this.traffic72hGb,
  });
  factory XuiClient.fromJson(Map<String, dynamic> j) {
    // Try several possible field names for the 72h-traffic total. If none
    // are present the value stays null and the UI shows "—". When the field
    // is present (even as 0, which happens during the first ~72h after agent
    // restart before any history accumulates), we return 0.0 so the UI shows
    // "0.0 GB" rather than the placeholder.
    double? parse72h() {
      // Pre-computed total (GB)
      final totalGb = j['traffic_72h_gb'] ?? j['bytes_72h_gb'];
      if (totalGb is num) return totalGb.toDouble();
      // Pre-computed total (bytes) → GB
      final totalBytes = j['traffic_72h_bytes'] ?? j['bytes_72h'];
      if (totalBytes is num) {
        return totalBytes.toDouble() / (1024 * 1024 * 1024);
      }
      // Sum of up + down 72h
      final up = j['up_72h_bytes'];
      final down = j['down_72h_bytes'];
      if (up is num && down is num) {
        return (up.toDouble() + down.toDouble()) / (1024 * 1024 * 1024);
      }
      return null;
    }

    return XuiClient(
      email: _s(j['email']),
      online: _b(j['online']),
      enable: _b(j['enable']),
      upBytes: _i(j['up_bytes']),
      downBytes: _i(j['down_bytes']),
      upMb: _d(j['up_mb']),
      downMb: _d(j['down_mb']),
      upGb: _d(j['up_gb']),
      downGb: _d(j['down_gb']),
      lastOnline: _i(j['last_online']),
      traffic72hGb: parse72h(),
    );
  }
  int get totalBytes => upBytes + downBytes;
  double get totalGb => upGb + downGb;
  int get secondsSinceLastOnline =>
      ((DateTime.now().millisecondsSinceEpoch - lastOnline) / 1000).round();
}

class XuiInbound {
  final String remark;
  final int port;
  final bool enable;
  final int upBytes;
  final int downBytes;
  final double upGb;
  final double downGb;
  const XuiInbound({
    required this.remark,
    required this.port,
    required this.enable,
    required this.upBytes,
    required this.downBytes,
    required this.upGb,
    required this.downGb,
  });
  factory XuiInbound.fromJson(Map<String, dynamic> j) => XuiInbound(
        remark: _s(j['remark']),
        port: _i(j['port']),
        enable: _b(j['enable']),
        upBytes: _i(j['up_bytes']),
        downBytes: _i(j['down_bytes']),
        upGb: _d(j['up_gb']),
        downGb: _d(j['down_gb']),
      );
}

class XuiInfo {
  final int onlineCount;
  final int totalClients;
  final double totalUpGb;
  final double totalDownGb;
  final List<XuiClient> clients;
  final List<XuiInbound> inbounds;
  const XuiInfo({
    required this.onlineCount,
    required this.totalClients,
    required this.totalUpGb,
    required this.totalDownGb,
    required this.clients,
    required this.inbounds,
  });
  factory XuiInfo.fromJson(Map<String, dynamic> j) => XuiInfo(
        onlineCount: _i(j['online_count']),
        totalClients: _i(j['total_clients']),
        totalUpGb: _d(j['total_up_gb']),
        totalDownGb: _d(j['total_down_gb']),
        clients: ((j['clients'] as List?) ?? [])
            .map((e) => XuiClient.fromJson(e as Map<String, dynamic>))
            .toList(),
        inbounds: ((j['inbounds'] as List?) ?? [])
            .map((e) => XuiInbound.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ServiceEntry {
  final String name;
  final String status;
  const ServiceEntry({required this.name, required this.status});
  factory ServiceEntry.fromJson(Map<String, dynamic> j) =>
      ServiceEntry(name: _s(j['name']), status: _s(j['status']));
  bool get isActive => status == 'active';
  bool get isFailed => status == 'failed';
}

/// A registered server (from /api/servers).
class MonitorServer {
  final String id;
  final String name;
  final String host;
  final int port;
  final String user;
  final String kind;     // "agent" or "ssh"
  final bool https;
  final bool savePass;
  final bool hasPass;
  final String? agentUrl;
  final Map<String, String> diskAliases;  // mount -> human label
  final Map<String, bool> hiddenDisks;    // mount -> true (hidden)
  final int createdAt;
  final int updatedAt;
  final int sortOrder;   // 用户在概览里拖拽排序的结果

  const MonitorServer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.user,
    required this.kind,
    this.https = false,
    this.savePass = false,
    this.hasPass = false,
    this.agentUrl,
    this.diskAliases = const {},
    this.hiddenDisks = const {},
    this.createdAt = 0,
    this.updatedAt = 0,
    this.sortOrder = 0,
  });

  factory MonitorServer.fromJson(Map<String, dynamic> j) => MonitorServer(
        id: _s(j['id']),
        name: _s(j['name']).isNotEmpty ? _s(j['name']) : _s(j['host']),
        host: _s(j['host']),
        port: _i(j['port']),
        user: _s(j['user']),
        kind: _s(j['kind']).isNotEmpty ? _s(j['kind']) : 'ssh',
        https: _b(j['https']),
        savePass: _b(j['save_pass']),
        hasPass: _b(j['has_pass']),
        agentUrl: j['agent_url'] as String?,
        diskAliases: _strMap(j['disk_aliases']),
        hiddenDisks: _boolMap(j['hidden_disks']),
        createdAt: _i(j['created_at']),
        updatedAt: _i(j['updated_at']),
        sortOrder: _i(j['sort_order']),
      );

  /// Serialize for SharedPreferences. We persist everything the runtime
  /// needs to re-establish the connection (incl. `agent_url`); tokens are
  /// added by the store layer (separate field — see store.dart).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'user': user,
        'kind': kind,
        'https': https,
        'save_pass': savePass,
        'has_pass': hasPass,
        if (agentUrl != null) 'agent_url': agentUrl,
        'disk_aliases': diskAliases,
        'hidden_disks': hiddenDisks,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'sort_order': sortOrder,
      };

  bool get isAgent => kind == 'agent';
  bool get isSsh => kind == 'ssh';

  /// Human-readable location string for sub-titles and detail headers.
  /// Agent mode → prefer [agentUrl] (the full agent endpoint).
  /// SSH mode → "host:port" with user.
  String get displayLocation {
    if (isAgent) {
      final u = (agentUrl ?? '').isNotEmpty ? agentUrl! : host;
      return '$u  ·  agent';
    }
    return '$host:$port  ·  $user';
  }

  MonitorServer copyWith({
    String? name,
    String? host,
    int? port,
    String? agentUrl,
    bool? https,
    Map<String, String>? diskAliases,
    Map<String, bool>? hiddenDisks,
    int? sortOrder,
  }) =>
      MonitorServer(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        user: user,
        kind: kind,
        https: https ?? this.https,
        savePass: savePass,
        hasPass: hasPass,
        agentUrl: agentUrl ?? this.agentUrl,
        diskAliases: diskAliases ?? this.diskAliases,
        hiddenDisks: hiddenDisks ?? this.hiddenDisks,
        createdAt: createdAt,
        updatedAt: updatedAt,
        sortOrder: sortOrder ?? this.sortOrder,
      );
}

Map<String, String> _strMap(dynamic v) {
  if (v is! Map) return const {};
  return v.map((k, val) => MapEntry(k.toString(), (val ?? '').toString()));
}

Map<String, bool> _boolMap(dynamic v) {
  if (v is! Map) return const {};
  return v.map((k, val) => MapEntry(k.toString(), val == true));
}

/// One server's data payload, after ServerData → Dart conversion.
class ServerData {
  final String id;
  final String name;
  final String kind;          // "nas" | "vps"
  final bool online;
  final String? error;
  final int ts;
  final int secondsAgo;
  final String source;        // "agent" | "ssh"
  final Hardware? hardware;
  final XuiInfo? xui;
  final List<ServiceEntry> services;

  const ServerData({
    required this.id,
    required this.name,
    required this.kind,
    required this.online,
    this.error,
    required this.ts,
    required this.secondsAgo,
    required this.source,
    this.hardware,
    this.xui,
    required this.services,
  });

  factory ServerData.fromJson(Map<String, dynamic> j) {
    final hw = j['hardware'] is Map
        ? Hardware.fromJson(j['hardware'] as Map<String, dynamic>)
        : null;
    return ServerData(
      id: _s(j['id']),
      name: _s(j['name']),
      kind: _s(j['kind']).isNotEmpty ? _s(j['kind']) : 'nas',
      online: _b(j['online']),
      error: j['error'] as String?,
      ts: _i(j['ts']),
      secondsAgo: _i(j['seconds_ago']),
      source: _s(j['source']).isNotEmpty ? _s(j['source']) : 'agent',
      hardware: hw,
      xui: j['xui'] is Map ? XuiInfo.fromJson(j['xui'] as Map<String, dynamic>) : null,
      services: ((j['services'] as List?) ?? [])
          .map((e) => ServiceEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  bool get isVps => kind == 'vps';
  bool get isNas => kind == 'nas';
  bool get isLive => online && secondsAgo >= 0 && secondsAgo < 30;
  bool get isStale => online && secondsAgo >= 30 && secondsAgo < 300;
  bool get isOffline => !online || secondsAgo >= 300 || secondsAgo < 0;
  bool get hasXui => xui != null;
}

/// Per-server entry in /api/snapshot — wraps ServerData with metadata.
class AgentData {
  final String name;
  final int timestamp;
  final int secondsAgo;
  final String id;
  final String kind;          // "nas" | "vps"
  final String source;        // "agent" | "ssh"
  final bool online;
  final Hardware? hardware;
  final XuiInfo? xui;
  final List<ServiceEntry> services;

  const AgentData({
    required this.name,
    required this.id,
    required this.kind,
    required this.source,
    required this.timestamp,
    required this.secondsAgo,
    required this.online,
    this.hardware,
    this.xui,
    required this.services,
  });

  /// Parse the v2.0.0 agent's direct response.
  ///
  /// v2.0.0 agent (no backend) returns:
  ///   {
  ///     "agent_name": "VPS",
  ///     "timestamp": 1786207283,      // unix seconds
  ///     "hardware": {...},            // already Hardware.fromJson shape
  ///     "xui": {...},                 // already XuiInfo.fromJson shape (or absent)
  ///     "services": [{"name", "status"}, ...]  // or absent
  ///   }
  ///
  /// For backward compat we also accept the legacy v1.0.x backend shape:
  ///   { "data": {...}, "last_update": ..., "seconds_ago": ... }
  factory AgentData.fromJson(Map<String, dynamic> j) {
    // Detect legacy backend shape: has "data" wrapper.
    final isLegacy = j.containsKey('data') && j['data'] is Map;
    if (isLegacy) {
      final data = j['data'] as Map<String, dynamic>;
      final sd = ServerData.fromJson(data);
      final kind = (sd.kind.isNotEmpty && sd.kind != 'nas') || sd.hasXui
          ? (sd.kind == 'nas' && sd.hasXui ? 'vps' : sd.kind)
          : sd.kind;
      return AgentData(
        name: sd.name.isNotEmpty ? sd.name : _s(data['agent_name']),
        id: sd.id,
        kind: kind,
        source: sd.source,
        timestamp: _i(j['last_update']),
        secondsAgo: _i(j['seconds_ago']),
        online: sd.online,
        hardware: sd.hardware,
        xui: sd.xui,
        services: sd.services,
      );
    }

    // v2.0.0 agent direct shape: flat response.
    final tsSec = _i(j['timestamp']);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final secondsAgo = tsSec > 0
        ? ((nowMs / 1000 - tsSec).round())
        : 0;
    final hasXui = j['xui'] is Map;
    return AgentData(
      name: _s(j['agent_name']),
      id: '',
      kind: hasXui ? 'vps' : 'nas',
      source: 'agent',
      timestamp: tsSec,
      secondsAgo: secondsAgo,
      online: true,
      hardware: j['hardware'] is Map
          ? Hardware.fromJson(j['hardware'] as Map<String, dynamic>)
          : null,
      xui: j['xui'] is Map
          ? XuiInfo.fromJson(j['xui'] as Map<String, dynamic>)
          : null,
      services: ((j['services'] as List?) ?? const [])
          .map((e) => ServiceEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  bool get isOnline => online && secondsAgo >= 0 && secondsAgo < 30;
  bool get isStale => secondsAgo >= 30 && secondsAgo < 300;
  bool get isOffline => !online || secondsAgo >= 300 || secondsAgo < 0;
  bool get isLive => isOnline;
  bool get isVps => kind == 'vps';
  bool get isNas => kind == 'nas';
  bool get hasXui => xui != null;
}

