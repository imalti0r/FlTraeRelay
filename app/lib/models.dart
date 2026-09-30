// models.dart - 数据模型：config.json 映射、/v1/status、/v1/models、usage 记录。
// RelayConfig 直接持有原始 JSON map，已知字段通过 getter/setter 读写，
// 未知字段在保存时原样保留（与 C++ Config::toJson 的 rawUnknown 行为一致）。

import 'dart:math';

/// config.json 的内存映射。raw 保留整份 JSON，写回时不丢字段。
class RelayConfig {
  RelayConfig(this.raw);

  final Map<String, dynamic> raw;

  Map<String, dynamic> _section(String name) {
    final v = raw[name];
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return v.map((k, value) => MapEntry(k.toString(), value));
    final fresh = <String, dynamic>{};
    raw[name] = fresh;
    return fresh;
  }

  // ---------- service ----------
  String get serviceHost => _str('service', 'host', '127.0.0.1');
  set serviceHost(String v) => _section('service')['host'] = v;
  int get servicePort => _int('service', 'port', 8317);
  set servicePort(int v) => _section('service')['port'] = v;
  bool get allowLan => _bool('service', 'allowLan', false);
  set allowLan(bool v) => _section('service')['allowLan'] = v;
  String get apiKey => _str('service', 'apiKey', '');
  set apiKey(String v) => _section('service')['apiKey'] = v;
  bool get allowAnyApiKey => _bool('service', 'allowAnyApiKey', false);
  set allowAnyApiKey(bool v) => _section('service')['allowAnyApiKey'] = v;
  int get maxConcurrentPerAccount => _int('service', 'maxConcurrentPerAccount', 2);
  set maxConcurrentPerAccount(int v) => _section('service')['maxConcurrentPerAccount'] = v;

  // ---------- defaults ----------
  String? get reasoningEffort {
    final v = _section('defaults')['reasoningEffort'];
    return v is String && v.isNotEmpty ? v : null;
  }
  set reasoningEffort(String? v) =>
      _section('defaults')['reasoningEffort'] = (v == null || v.isEmpty) ? null : v;
  int get isMaxMode => _int('defaults', 'isMaxMode', 0);
  set isMaxMode(int v) => _section('defaults')['isMaxMode'] = v;
  bool get stream => _bool('defaults', 'stream', false);
  set stream(bool v) => _section('defaults')['stream'] = v;
  bool get autoContinue => _bool('defaults', 'autoContinue', true);
  set autoContinue(bool v) => _section('defaults')['autoContinue'] = v;

  // ---------- responses ----------
  bool get responsesEnabled => _bool('responses', 'enabled', true);
  set responsesEnabled(bool v) => _section('responses')['enabled'] = v;
  int get sessionCacheSize => _int('responses', 'sessionCacheSize', 64);
  set sessionCacheSize(int v) => _section('responses')['sessionCacheSize'] = v;
  bool get sessionCachePersist => _bool('responses', 'sessionCachePersist', false);
  set sessionCachePersist(bool v) => _section('responses')['sessionCachePersist'] = v;

  // ---------- accounts ----------
  bool get accountsAutoDiscover => _bool('accounts', 'autoDiscover', true);
  set accountsAutoDiscover(bool v) => _section('accounts')['autoDiscover'] = v;
  bool get checkinEnabled => _nestedBool(_checkinPath, 'enabled', true);
  set checkinEnabled(bool v) => _map(_checkinPath)['enabled'] = v;
  int get checkinHour => _nestedInt(_checkinPath, 'hour', 10);
  set checkinHour(int v) => _map(_checkinPath)['hour'] = v;
  int get checkinMinute => _nestedInt(_checkinPath, 'minute', 0);
  set checkinMinute(int v) => _map(_checkinPath)['minute'] = v;
  String get poolSelectBy => _nestedStr(_poolPath, 'selectBy', 'credits');
  set poolSelectBy(String v) => _map(_poolPath)['selectBy'] = v;

  static const _checkinPath = ['accounts', 'checkin'];
  static const _poolPath = ['accounts', 'pool'];

  /// models.<name> 覆盖项（与 C++ ModelConfig 对应）。不存在时返回 null。
  Map<String, dynamic>? modelOverride(String name) {
    final v = _section('models')[name];
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return v.map((k, value) => MapEntry(k.toString(), value));
    return null;
  }

  /// 写入 models.<name> 覆盖项（present 语义：出现即生效，不存在 enabled=true）。
  void upsertModelOverride(String name, Map<String, dynamic> fields) {
    final existing = modelOverride(name) ?? <String, dynamic>{};
    existing.addAll(fields);
    existing.removeWhere((k, v) => v == null);
    _section('models')[name] = existing;
  }

  String? modelReasoningEffort(String name) {
    final v = modelOverride(name)?['reasoningEffort'];
    return v is String && v.isNotEmpty ? v : null;
  }

  int? modelIsMaxMode(String name) {
    final v = modelOverride(name)?['isMaxMode'];
    return v is int ? v : null;
  }

  // ---------- logging ----------
  bool get loggingEnabled => _bool('logging', 'enabled', true);
  set loggingEnabled(bool v) => _section('logging')['enabled'] = v;
  String get logLevel => _str('logging', 'level', 'info');
  set logLevel(String v) => _section('logging')['level'] = v;
  int get logRetainDays => _int('logging', 'retainDays', 7);
  set logRetainDays(int v) => _section('logging')['retainDays'] = v;

  String get baseUrl => 'http://${serviceHost == '0.0.0.0' ? '127.0.0.1' : serviceHost}:$servicePort';

  String _str(String sec, String key, String def) {
    final v = _section(sec)[key];
    return v is String ? v : def;
  }

  /// 取嵌套节点（自动创建父级），如 path = ['accounts', 'checkin']。
  Map<String, dynamic> _map(List<String> path) {
    Map<String, dynamic> cur = raw;
    for (final seg in path) {
      final next = cur[seg];
      if (next is Map<String, dynamic>) {
        cur = next;
      } else if (next is Map) {
        final converted = next.map((k, v) => MapEntry(k.toString(), v));
        cur[seg] = converted; // 统一为可变 String-key map，写回父级
        cur = converted;
      } else {
        final fresh = <String, dynamic>{};
        cur[seg] = fresh;
        cur = fresh;
      }
    }
    return cur;
  }

  bool _nestedBool(List<String> path, String key, bool def) {
    final v = _map(path)[key];
    return v is bool ? v : def;
  }

  int _nestedInt(List<String> path, String key, int def) {
    final v = _map(path)[key];
    return v is int ? v : def;
  }

  String _nestedStr(List<String> path, String key, String def) {
    final v = _map(path)[key];
    return v is String ? v : def;
  }

  int _int(String sec, String key, int def) {
    final v = _section(sec)[key];
    return v is int ? v : def;
  }

  bool _bool(String sec, String key, bool def) {
    final v = _section(sec)[key];
    return v is bool ? v : def;
  }

  /// 生成与 C++ crypto::genApiKey 相同格式的密钥：sk-trae- + 12 字节 hex。
  static String genApiKey() {
    final rng = Random.secure();
    const hexChars = '0123456789abcdef';
    final sb = StringBuffer('sk-trae-');
    for (var i = 0; i < 24; i++) {
      sb.write(hexChars[rng.nextInt(16)]);
    }
    return sb.toString();
  }
}

/// /v1/status 的 accounts[] 元素。
class AccountInfo {
  const AccountInfo({
    required this.nickname,
    required this.edition,
    required this.credits,
    required this.active,
  });

  factory AccountInfo.fromJson(Map<String, dynamic> j) => AccountInfo(
        nickname: (j['nickname'] ?? '').toString(),
        edition: (j['edition'] ?? '').toString(),
        credits: (j['credits'] as num?)?.toDouble() ?? -1,
        active: (j['active'] as num?)?.toInt() ?? 0,
      );

  final String nickname;
  final String edition;
  final double credits;
  final int active;

  bool get busy => active > 0;
}

/// /v1/status 响应。
class RelayStatus {
  const RelayStatus({required this.accounts});

  factory RelayStatus.fromJson(Map<String, dynamic> j) => RelayStatus(
        accounts: ((j['accounts'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => AccountInfo.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
            .toList(),
      );

  final List<AccountInfo> accounts;
}

/// /v1/models 响应元素。
class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.displayName,
    required this.maxMode,
    required this.effortOptions,
  });

  factory ModelInfo.fromJson(Map<String, dynamic> j) => ModelInfo(
        id: (j['id'] ?? '').toString(),
        displayName: (j['display_name'] ?? '').toString(),
        maxMode: j['max_mode'] == true,
        effortOptions: ((j['reasoning_effort_options'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  final String id;
  final String displayName;
  final bool maxMode;
  final List<String> effortOptions;

  String get label => displayName.isEmpty ? id : displayName;
}

/// usage/usage-YYYYMMDD.jsonl 的一行（与 C++ UsageRecord 对应）。
class UsageRecord {
  const UsageRecord({
    required this.ts,
    required this.account,
    required this.model,
    required this.endpoint,
    required this.input,
    required this.output,
    required this.cache,
    required this.creditsDelta,
    required this.creditsKnown,
    required this.ms,
    required this.ok,
  });

  factory UsageRecord.fromJson(Map<String, dynamic> j) => UsageRecord(
        ts: DateTime.tryParse((j['ts'] ?? '').toString().replaceFirst(' ', 'T')) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        account: (j['account'] ?? '').toString(),
        model: (j['model'] ?? '').toString(),
        endpoint: (j['ep'] ?? '').toString(),
        input: _asInt(j['in']),
        output: _asInt(j['out']),
        cache: _asInt(j['cache']),
        creditsDelta: (j['delta'] as num?)?.toDouble() ?? 0,
        creditsKnown: j['known'] == true,
        ms: _asInt(j['ms']),
        ok: j['ok'] != false,
      );

  static int _asInt(dynamic v) => (v as num?)?.toInt() ?? 0;

  final DateTime ts;
  final String account;
  final String model;
  final String endpoint;
  final int input;
  final int output;
  final int cache;
  final double creditsDelta;
  final bool creditsKnown;
  final int ms;
  final bool ok;

  int get tokens => input + output;
}

/// 某一天的用量汇总。
class TodayUsage {
  TodayUsage({required this.requests, required this.tokens, required this.credits});

  int requests = 0;
  int tokens = 0;
  double credits = 0;
}
