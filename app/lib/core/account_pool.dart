// account_pool.dart - 账号池：发现、并发闸门、令牌刷新、积分同步、使用记录、签到。
// 对应 C++ src/accounts/AccountPool.cpp。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'account_snapshot.dart';
import 'auth.dart';
import 'crypto_x.dart';
import 'model_caps.dart';
import 'model_catalog.dart';
import 'storage.dart';
import 'token_refresh.dart';
import 'upstream.dart';

/// 一条使用记录（usage/usage-YYYYMMDD.jsonl 的一行）。
class UsageRecord {
  UsageRecord({
    required this.ts,
    required this.account,
    required this.model,
    required this.endpoint,
    required this.input,
    required this.output,
    required this.cache,
    required this.creditsBefore,
    required this.creditsAfter,
    required this.creditsDelta,
    required this.creditsKnown,
    required this.merged,
    required this.ms,
    required this.ok,
    this.detail,
  });

  final DateTime ts;
  final String account;
  final String model;
  final String endpoint;
  final int input;
  final int output;
  final int cache;
  final double creditsBefore;
  final double creditsAfter;
  final double creditsDelta;
  final bool creditsKnown;
  final bool merged;
  final int ms;
  final bool ok;

  /// 请求与响应详情（可选）：{ messages: [...], text, reasoning, toolCalls: [...] }
  final Map<String, dynamic>? detail;

  Map<String, dynamic> toJson() {
    final j = <String, dynamic>{
      'ts': _tsFormat(ts),
      'account': account,
      'model': model,
      'ep': endpoint,
      'in': input,
      'out': output,
      'cache': cache,
      'before': creditsBefore,
      'after': creditsAfter,
      'delta': creditsDelta,
      'known': creditsKnown,
      'merged': merged,
      'ms': ms,
      'ok': ok,
    };
    // detail 大（含完整对话体），独立文件存放：detail.json/<ts>.json，
    // jsonl 里只放指针，避免主记录文件膨胀。
    if (detail != null && detail!.isNotEmpty) {
      j['detail'] = detailFile;
    }
    return j;
  }

  /// 与 jsonl 行一起写入时设置的详情文件名（相对 detail 目录）。
  String detailFile = '';

  static String _tsFormat(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

class TodayUsage {
  int requests = 0;
  int tokens = 0;
  double credits = 0;
}

/// 待落账的请求（积分差值等补查后回填）。
class _UsagePending {
  _UsagePending(this.account, this.model, this.endpoint, this.input, this.output, this.cache, this.ms,
      [this.detail]);
  final Account account;
  final String model;
  final String endpoint;
  final int input;
  final int output;
  final Map<String, dynamic>? detail;
  final int cache;
  final int ms;
  final DateTime ts = DateTime.now();
  double creditsBefore = 0;
  bool beforeKnown = false;
}

class AccountPool implements AccountProvider {
  AccountPool(this.dataDir) {
    _usageDir = '$dataDir\\usage';
  }

  /// 数据目录（%APPDATA%\FlTraeRelay，账号快照与使用记录都在其下）。
  final String dataDir;
  late String _usageDir;

  final http.Client _client = http.Client();
  final List<Account> _accounts = [];
  late AccountSnapshotStore _snapshots = AccountSnapshotStore(dataDir);

  int _rr = 0;
  int _maxConcurrentPerAccount = 2;
  int _minRequestIntervalMs = 0;
  String _poolSelectBy = 'credits';
  final Set<String> _disabledIds = {}; // 停用的账号 id（调度跳过）
  final Set<String> _deletedIds = {};  // 已删除的账号 id（发现跳过）
  String _ideVersion = '';
  String _ideVersionCode = '';
  bool _checkinEnabled = true;
  int _checkinHour = 10;
  int _checkinMinute = 0;
  Timer? _checkinTimer;
  DateTime _lastCheckinDay = DateTime(0);

  final List<_UsagePending> _usagePending = [];
  final List<UsageRecord> _usageCache = [];
  bool _usageCacheLoaded = false;
  DateTime _usageTodayStart = DateTime(0);
  DateTime _usageTodayEnd = DateTime(0);
  int _usageTodayCount = 0;
  int _usageTodayTokens = 0;
  double _usageTodayCredits = 0;

  // ---- AccountProvider ----
  @override
  List<Account> get accounts => List.unmodifiable(_accounts);

  @override
  Future<bool> ensureFreshToken(Account acc) => _ensureFreshToken(acc);

  // ---------- 发现 ----------

  /// 发现账号并合并私有快照：
  /// 1. 扫描当前客户端登录态（最新鲜），每个账号快照到 accounts/ 私有存储；
  /// 2. 加载全部快照——客户端切号后，历史账号从快照恢复，多账号共存；
  /// 3. 合并去重（按 userId），当前登录态覆盖同 userId 的旧快照。
  void autoDiscover({bool force = false}) {
    if (_accounts.isNotEmpty && !force) return;
    if (force) _accounts.clear();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final merged = <String, Account>{};

    // 1) 当前客户端登录态（优先，信息最新）
    for (final ed in discoverEditions()) {
      final (err, auth) = readAuth(ed.userDir);
      if (auth == null) continue;
      final acc = Account()
        ..auth = auth
        ..editionId = ed.id
        ..machineId = readMachineId(ed.userDir)
        ..deviceId = readAhaDeviceId(ed.userDir);
      if (acc.deviceId.isEmpty) acc.deviceId = readDeviceId(ed.userDir);
      if (acc.machineId.isEmpty) {
        acc.machineId =
            sha512Hex(utf8.encode('${acc.auth.userId}${acc.auth.accessToken}')).substring(0, 32);
      }
      if (acc.deviceId.isEmpty) acc.deviceId = acc.machineId;
      acc.nickname = _nicknameFor(acc.auth.userId);
      merged[acc.auth.userId] = acc;
      // 快照到私有存储（凭据与设备指纹齐全，切号后可恢复）
      _snapshots.save(
        userId: acc.auth.userId,
        auth: acc.auth,
        machineId: acc.machineId,
        deviceId: acc.deviceId,
        editionId: acc.editionId,
      );
    }

    // 2) 私有快照：恢复历史账号（当前登录态已存在的跳过）
    for (final snap in _snapshots.loadAll()) {
      if (merged.containsKey(snap.userId)) continue;
      final acc = Account()
        ..auth = snap.auth
        ..editionId = snap.editionId
        ..machineId = snap.machineId.isEmpty
            ? sha512Hex(utf8.encode('${snap.auth.userId}${snap.auth.accessToken}')).substring(0, 32)
            : snap.machineId
        ..deviceId = snap.deviceId.isEmpty ? snap.machineId : snap.deviceId
        ..nickname = _nicknameFor(snap.userId);
      // 快照里的 token 可能已过期：标一下，acquire 前的 ensureFreshToken 会刷
      if (acc.auth.expiredTs != 0 && acc.auth.expiredTs < now) {
        // 过期账号仍加入池子：刷新成功即可用，失败由调度隔离
      }
      merged[snap.userId] = acc;
    }

    // 3) 应用删除表
    for (final entry in merged.entries.toList()) {
      if (_deletedIds.contains('${entry.value.editionId}:${entry.key}') ||
          _deletedIds.contains(entry.key)) {
        merged.remove(entry.key);
      }
    }

    _accounts
      ..clear()
      ..addAll(merged.values);
  }

  String _nicknameFor(String userId) =>
      'Trae-${userId.length > 4 ? userId.substring(userId.length - 4) : userId}';

  // ---------- 配置推送 ----------

  void updateSettings({
    required int maxConcurrentPerAccount,
    required int minRequestIntervalMs,
    required String poolSelectBy,
    required String ideVersion,
    required String ideVersionCode,
    required bool checkinEnabled,
    required int checkinHour,
    required int checkinMinute,
    Set<String> disabledAccountIds = const {},
    Set<String> deletedAccountIds = const {},
  }) {
    _maxConcurrentPerAccount = maxConcurrentPerAccount.clamp(1, 8);
    _minRequestIntervalMs = minRequestIntervalMs;
    _poolSelectBy = poolSelectBy;
    _disabledIds
      ..clear()
      ..addAll(disabledAccountIds);
    _deletedIds
      ..clear()
      ..addAll(deletedAccountIds);
    _ideVersion = ideVersion;
    _ideVersionCode = ideVersionCode;
    _checkinEnabled = checkinEnabled;
    _checkinHour = checkinHour;
    _checkinMinute = checkinMinute;
    _scheduleCheckin();
  }

  // ---------- 并发闸门 ----------

  /// 获取一个可用账号；等待 [timeout]，超时返回 null。
  /// 返回的槽位由调用方 release()；[lease] 为兜底租约——超时未释放则强制
  /// 回收，防止异常/中断路径（客户端断开、上游挂起）永久占用并发槽。
  Future<Account?> acquire(
    [Duration timeout = const Duration(seconds: 30),
    Duration lease = const Duration(minutes: 20)]) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final picked = _tryPick();
      if (picked != null) {
        _leaseTimers[picked]?.cancel();
        _leaseTimers[picked] = Timer(lease, () {
          if (picked.active > 0) {
            picked.active -= 1;
          }
          _leaseTimers.remove(picked);
        });
        return picked;
      }
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  final Map<Account, Timer> _leaseTimers = {};

  Account? _tryPick() {
    if (_accounts.isEmpty) return null;
    final now = DateTime.now();
    final avail = [
      ..._accounts.where((a) => !_disabledIds.contains(a.id)),
    ];
    if (avail.isEmpty) return null;
    Account picked;
    switch (_poolSelectBy) {
      case 'roundRobin':
        // 轮询：从 _rr 起找第一个并发未满的
        picked = avail[_rr % avail.length];
        for (var i = 0; i < avail.length; i++) {
          final cand = avail[(_rr + i) % avail.length];
          if (cand.active < _maxConcurrentPerAccount) {
            picked = cand;
            _rr = (_rr + i + 1) % avail.length;
            break;
          }
        }
        break;
      case 'expiry':
        // 到期优先：token 最先过期的先用（未知的排最后），
        // 避免"临期账号额度作废浪费"。
        int expKey(Account a) =>
            a.auth.expiredTs == 0 ? 0x7FFFFFFFFFFFFFFF : a.auth.expiredTs;
        avail.sort((a, b) => expKey(a).compareTo(expKey(b)));
        picked = avail.first;
        break;
      case 'credits':
      default:
        // 余额优先：积分降序，未知(-1)排后
        avail.sort((a, b) => b.credits.compareTo(a.credits));
        picked = avail.first;
        break;
    }
    // 最小请求间隔
    if (_minRequestIntervalMs > 0 && picked.lastRequestTsMs > 0) {
      final gap = now.millisecondsSinceEpoch - picked.lastRequestTsMs;
      if (gap < _minRequestIntervalMs) {
        for (final a in avail) {
          if (!identical(a, picked) && now.millisecondsSinceEpoch - a.lastRequestTsMs >= _minRequestIntervalMs) {
            picked = a;
            break;
          }
        }
      }
    }
    if (picked.active >= _maxConcurrentPerAccount) return null;
    picked.active += 1;
    picked.lastRequestTsMs = now.millisecondsSinceEpoch;
    return picked;
  }

  /// 停用账号（调度立即跳过；正在进行的请求不受影响）。
  void disableAccount(String accountId) => _disabledIds.add(accountId);

  /// 启用账号。
  void enableAccount(String accountId) => _disabledIds.remove(accountId);

  /// 从池中移除账号（重新发现时会按删除表跳过），并删除私有快照。
  void removeAccount(String accountId) {
    _disabledIds.add(accountId);
    _accounts.removeWhere((a) => a.id == accountId);
    final uid = accountId.contains(':') ? accountId.split(':')[1] : accountId;
    _snapshots.delete(uid);
  }

  /// 账号是否被停用。
  bool isDisabled(String accountId) => _disabledIds.contains(accountId);

  void release(Account acc, bool ok, int errorCode) {
    _leaseTimers.remove(acc)?.cancel();
    if (acc.active > 0) acc.active -= 1;
    acc.lastUsedTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  bool get hasUsableAccount => _accounts.isNotEmpty;

  // ---------- 令牌 ----------

  Future<bool> _ensureFreshToken(Account acc) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (!needsRefresh(acc.auth, now)) {
      return true;
    }
    final rr = await exchangeToken(acc.auth);
    if (!rr.ok || rr.auth == null) {
      return acc.auth.expiredTs == 0 || acc.auth.expiredTs > now;
    }
    acc.auth = rr.auth!;
    return true;
  }

  // ---------- 积分 ----------

  String _apiHost(Account acc) {
    var host = 'https://api.trae.cn';
    if (acc.auth.host.startsWith('http')) host = acc.auth.host;
    while (host.endsWith('/')) {
      host = host.substring(0, host.length - 1);
    }
    return host;
  }

  Map<String, String> _ideHeadersFor(Account acc, {bool sse = false}) =>
      ideHeaders(acc, _ideVersion, _ideVersionCode, sse: sse);

  /// 拉会员身份（ide_user_pay_status）。0=Free；-1 未知。
  Future<void> refreshPayIdentity(Account acc) async {
    try {
      final resp = await _client
          .post(Uri.parse('${_apiHost(acc)}/trae/api/v2/pay/ide_user_pay_status'),
              headers: _ideHeadersFor(acc), body: jsonEncode({'req_source': 0}))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        acc.payIdentity = -1;
        return;
      }
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      final value = _findPayIdentityDeep(j, 0);
      acc.payIdentity = value;
    } catch (_) {
      acc.payIdentity = -1;
    }
  }

  static int _findPayIdentityDeep(dynamic j, int depth) {
    if (depth > 6) return -1;
    if (j is Map) {
      for (final key in ['pay_identity', 'payIdentity', 'is_member', 'isMember']) {
        final v = j[key];
        if (v is num) return v.toInt();
        if (v is bool) return v ? 1 : 0;
      }
      for (final v in j.values) {
        if (v is Map || v is List) {
          final r = _findPayIdentityDeep(v, depth + 1);
          if (r >= 0) return r;
        }
      }
    } else if (j is List) {
      for (final v in j) {
        if (v is Map || v is List) {
          final r = _findPayIdentityDeep(v, depth + 1);
          if (r >= 0) return r;
        }
      }
    }
    return -1;
  }

  /// usage_summary 深搜：total - consumed 或 remaining。
  static bool _findUsageSummaryDeep(dynamic j, List<double> out, [int depth = 0]) {
    if (depth > 8) return false;
    if (j is Map) {
      final summary = j['usage_summary'];
      if (summary is Map) {
        double? number(dynamic v) {
          if (v is num) return v.toDouble();
          if (v is String) return double.tryParse(v);
          return null;
        }
        final remaining = number(summary['remaining_amount']) ?? number(summary['available_amount']);
        if (remaining != null) {
          out.add(remaining < 0 ? 0 : remaining);
          return true;
        }
        final total = number(summary['total_amount']);
        final consumed = number(summary['consumed_amount']);
        if (total != null && consumed != null) {
          final value = total - consumed;
          out.add(value < 0 ? 0 : value);
          return true;
        }
      }
      for (final v in j.values) {
        if (v is Map || v is List) {
          if (_findUsageSummaryDeep(v, out, depth + 1)) return true;
        }
      }
    } else if (j is List) {
      for (final v in j) {
        if (v is Map || v is List) {
          if (_findUsageSummaryDeep(v, out, depth + 1)) return true;
        }
      }
    }
    return false;
  }

  /// 主动刷新积分（ide_user_ent_usage）。同时把补查队列的积分差值落账。
  Future<bool> refreshCredits([Account? acc]) async {
    final targets = acc != null ? [acc] : [..._accounts];
    var anyOk = false;
    for (final a in targets) {
      if (!await _ensureFreshToken(a)) continue;
      await refreshPayIdentity(a);
      final host = _apiHost(a);
      // 使用记录口径：此刻余额即"补查前余额"
      final beforeCredits = a.credits;
      try {
        final resp = await _client
            .post(Uri.parse('$host/trae/api/v2/pay/ide_user_ent_usage'),
                headers: _ideHeadersFor(a),
                body: jsonEncode({'require_usage': true, 'req_source': 0}))
            .timeout(const Duration(seconds: 20));
        if (resp.statusCode != 200) continue;
        final j = jsonDecode(utf8.decode(resp.bodyBytes));
        final out = <double>[];
        if (!_findUsageSummaryDeep(j, out)) continue;
        a.credits = out.first;
        a.creditsFresh = true;
        anyOk = true;
        _settlePending(a, beforeCredits, out.first);
      } catch (_) {}
    }
    return anyOk;
  }

  /// 把等待积分回填的记录按"补查前余额 − 补查后余额"落账。
  void _settlePending(Account a, double before, double after) {
    if (_usagePending.isEmpty) return;
    final mine = _usagePending.where((p) => identical(p.account, a)).toList();
    if (mine.isEmpty) return;
    final delta = before - after;
    for (final p in mine) {
      _usagePending.remove(p);
      final rec = UsageRecord(
        ts: p.ts,
        account: a.nickname,
        model: p.model,
        endpoint: p.endpoint,
        input: p.input,
        output: p.output,
        cache: p.cache,
        creditsBefore: before,
        creditsAfter: after,
        creditsDelta: delta,
        creditsKnown: true,
        merged: mine.length > 1,
        ms: p.ms,
        ok: true,
        detail: p.detail,
      );
      _usageAppend(rec);
    }
  }

  /// 上游 usage 事件里同步积分（notify_usage 通常携带新余额）。
  void updateCreditsFromEvent(Account acc, Map<String, dynamic> event) {
    final out = <double>[];
    if (_findUsageSummaryDeep(event, out)) {
      acc.credits = out.first;
      acc.creditsFresh = true;
    }
  }

  /// 请求收尾登记：token 已知，积分差值等补查时落账。
  void usageRecordPending(
      Account acc, ModelCaps model, String endpoint, int input, int output, int cache, int ms,
      [Map<String, dynamic>? detail]) {
    _usagePending.add(_UsagePending(acc, model.configName, endpoint, input, output, cache, ms, detail));
    // 延迟兜底：10 秒内没有积分回填就先按未知落账，避免记录悬挂
    Future<void>.delayed(const Duration(seconds: 10), () {
      final stuck = _usagePending.where((p) => identical(p.account, acc)).toList();
      for (final p in stuck) {
        _usagePending.remove(p);
        _usageAppend(UsageRecord(
          ts: p.ts,
          account: acc.nickname,
          model: p.model,
          endpoint: p.endpoint,
          input: p.input,
          output: p.output,
          cache: p.cache,
          creditsBefore: 0,
          creditsAfter: 0,
          creditsDelta: 0,
          creditsKnown: false,
          merged: false,
          ms: p.ms,
          ok: true,
          detail: p.detail,
        ));
      }
    });
  }

  // ---------- 使用记录 ----------

  void _usageAppend(UsageRecord r) {
    _ensureUsageDir();
    _usageCache.insert(0, r);
    final day = DateTime(r.ts.year, r.ts.month, r.ts.day);
    if (day.isAfter(_usageTodayStart) && day.isBefore(_usageTodayEnd)) {
      _usageTodayCount += 1;
      _usageTodayTokens += r.input + r.output;
      if (r.creditsKnown) _usageTodayCredits += r.creditsDelta;
    }
    final y = r.ts.year.toString().padLeft(4, '0');
    final m = r.ts.month.toString().padLeft(2, '0');
    final d = r.ts.day.toString().padLeft(2, '0');
    // 详情独立文件：detail/usage-YYYYMMDD/<HHmmss-SSS>.json，
    // jsonl 主记录里只放相对指针，避免对话体撑爆主文件。
    if (r.detail != null && r.detail!.isNotEmpty) {
      final detailDir = Directory('$_usageDir\\detail\\usage-$y$m$d');
      if (!detailDir.existsSync()) detailDir.createSync(recursive: true);
      String two(int n) => n.toString().padLeft(2, '0');
      final name =
          '${two(r.ts.hour)}${two(r.ts.minute)}${two(r.ts.second)}-${r.ts.millisecond.toString().padLeft(3, '0')}.json';
      File('${detailDir.path}\\$name').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(r.detail),
        flush: true,
      );
      r.detailFile = 'usage-$y$m$d/$name';
    }
    final f = File('$_usageDir\\usage-$y$m$d.jsonl');
    f.writeAsStringSync('${jsonEncode(r.toJson())}\n', mode: FileMode.append, flush: true);
  }

  void _ensureUsageDir() {
    final dir = Directory(_usageDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }

  /// 按指针读取详情：date=YYYY-MM-DD，time=HHmmss（详情文件名前缀）。
  Map<String, dynamic>? readDetailByPointer(String date, String time) {
    final compact = date.replaceAll('-', '');
    final rel = 'usage-$compact${Platform.pathSeparator}$time.json';
    final f = File('$_usageDir${Platform.pathSeparator}detail${Platform.pathSeparator}$rel');
    if (!f.existsSync()) return null;
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 读取一条记录的详情（请求消息与回复内容）。文件不存在返回 null。
  Map<String, dynamic>? readDetail(UsageRecord r) {
    if (r.detailFile.isEmpty) return null;
    try {
      // detailFile 内部用 '/' 分隔（jsonl 指针），这里统一转成平台分隔符
      final rel = r.detailFile.replaceAll('/', Platform.pathSeparator);
      final f = File('$_usageDir${Platform.pathSeparator}detail${Platform.pathSeparator}$rel');
      if (!f.existsSync()) return null;
      final decoded = jsonDecode(f.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 读取指定日期的记录（时间倒序）。
  List<UsageRecord> usagePage(DateTime day, [int limit = 500]) {
    _ensureUsageCache();
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final out = <UsageRecord>[];
    for (final r in _usageCache) {
      if (!r.ts.isBefore(start) && r.ts.isBefore(end)) {
        out.add(r);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  void _ensureUsageCache() {
    if (_usageCacheLoaded) return;
    _usageCacheLoaded = true;
    final dir = Directory(_usageDir);
    if (!dir.existsSync()) return;
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final f in files.take(30)) {
      try {
        for (final line in f.readAsLinesSync()) {
          if (line.trim().isEmpty) continue;
          try {
            final j = jsonDecode(line);
            if (j is Map) {
              _usageCache.add(_recordFromJson(j.map((k, v) => MapEntry(k.toString(), v))));
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    _usageCache.sort((a, b) => b.ts.compareTo(a.ts));
  }

  static UsageRecord _recordFromJson(Map<String, dynamic> j) {
    final ts = DateTime.tryParse((j['ts'] ?? '').toString().replaceFirst(' ', 'T')) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return UsageRecord(
      ts: ts,
      account: (j['account'] ?? '').toString(),
      model: (j['model'] ?? '').toString(),
      endpoint: (j['ep'] ?? '').toString(),
      input: (j['in'] as num?)?.toInt() ?? 0,
      output: (j['out'] as num?)?.toInt() ?? 0,
      cache: (j['cache'] as num?)?.toInt() ?? 0,
      creditsBefore: (j['before'] as num?)?.toDouble() ?? 0,
      creditsAfter: (j['after'] as num?)?.toDouble() ?? 0,
      creditsDelta: (j['delta'] as num?)?.toDouble() ?? 0,
      creditsKnown: j['known'] == true,
      merged: j['merged'] == true,
      ms: (j['ms'] as num?)?.toInt() ?? 0,
      ok: j['ok'] != false,
    )..detailFile = (j['detail'] ?? '').toString();
  }

  /// 今日汇总（本地日界，与 C++ usageCountToday 口径一致）。
  TodayUsage usageToday() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = todayStart.add(const Duration(days: 1));
    if (todayStart != _usageTodayStart || todayEnd != _usageTodayEnd) {
      _usageTodayStart = todayStart;
      _usageTodayEnd = todayEnd;
      _usageTodayCount = 0;
      _usageTodayTokens = 0;
      _usageTodayCredits = 0;
      _ensureUsageCache();
      for (final r in _usageCache) {
        if (!r.ts.isBefore(todayStart) && r.ts.isBefore(todayEnd)) {
          _usageTodayCount += 1;
          _usageTodayTokens += r.input + r.output;
          if (r.creditsKnown) _usageTodayCredits += r.creditsDelta;
        }
      }
    }
    return TodayUsage()
      ..requests = _usageTodayCount
      ..tokens = _usageTodayTokens
      ..credits = _usageTodayCredits;
  }

  // ---------- 签到 ----------

  static bool _findCheckinFlagDeep(dynamic j, [int depth = 0]) {
    if (depth > 8) return false;
    if (j is Map) {
      for (final key in ['did_checked_in', 'didCheckedIn', 'checked_in_today', 'has_checked_in']) {
        final v = j[key];
        if (v is bool) return v;
        if (v is num) return v != 0;
        if (v is String) {
          final p = v.toLowerCase();
          if (p == 'true' || p == '1') return true;
          if (p == 'false' || p == '0') return false;
        }
      }
      final checked = j['checked_in'];
      if (checked is bool) return checked;
      for (final v in j.values) {
        if (v is Map || v is List) {
          if (_findCheckinFlagDeep(v, depth + 1)) return true;
        }
      }
    } else if (j is List) {
      for (final v in j) {
        if (v is Map || v is List) {
          if (_findCheckinFlagDeep(v, depth + 1)) return true;
        }
      }
    }
    return false;
  }

  static int? _findCodeDeep(dynamic j, [int depth = 0]) {
    if (depth > 8) return null;
    if (j is Map) {
      for (final key in ['code', 'status_code', 'error_code']) {
        final v = j[key];
        int? candidate;
        if (v is num) candidate = v.toInt();
        if (v is String) candidate = int.tryParse(v);
        if (candidate != null && candidate != 0) return candidate;
      }
      for (final v in j.values) {
        if (v is Map || v is List) {
          final nested = _findCodeDeep(v, depth + 1);
          if (nested != null && nested != 0) return nested;
        }
      }
    } else if (j is List) {
      for (final v in j) {
        if (v is Map || v is List) {
          final nested = _findCodeDeep(v, depth + 1);
          if (nested != null && nested != 0) return nested;
        }
      }
    }
    return null;
  }

  /// 手动签到。返回 0=成功、1=今日已签、-1=失败。
  Future<int> doCheckin(Account acc) async {
    if (!await _ensureFreshToken(acc)) return -1;
    final host = _apiHost(acc);
    final hdr = _ideHeadersFor(acc);
    final request = jsonEncode({'req_source': acc.editionId == 'work' ? 2 : 1});
    try {
      final st = await _client
          .post(Uri.parse('$host/trae/api/v2/ug/checkin_credits/status'), headers: hdr, body: request)
          .timeout(const Duration(seconds: 15));
      if (st.statusCode != 200) return -1;
      final j = jsonDecode(utf8.decode(st.bodyBytes));
      if (_findCheckinFlagDeep(j)) return 1;
      final statusCode = _findCodeDeep(j);
      if (statusCode == 9095) return 1;
    } catch (_) {
      return -1;
    }

    // 9074 是签到活动并发限流，同一请求换时段即可成功 → 退避重试
    const retries = [15, 30, 45, 60, 60];
    for (var attempt = 0;; attempt++) {
      try {
        final cl = await _client
            .post(Uri.parse('$host/trae/api/v2/ug/checkin_credits/claim'), headers: hdr, body: request)
            .timeout(const Duration(seconds: 15));
        if (cl.statusCode != 200) return -1;
        final body = utf8.decode(cl.bodyBytes, allowMalformed: true);
        Map<String, dynamic>? j;
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) j = decoded;
        } catch (_) {}
        final code = j == null ? null : _findCodeDeep(j);
        if (j != null && code == 9074 && attempt < retries.length) {
          await Future<void>.delayed(Duration(seconds: retries[attempt]));
          continue;
        }
        final already = code == 9095;
        final flag = j != null && _findCheckinFlagDeep(j);
        final success = j != null && (code == null || code == 0);
        if (flag || success) {
          await refreshCredits(acc);
          return 0;
        }
        if (already) return 1;
        return -1;
      } catch (_) {
        return -1;
      }
    }
  }

  /// 自动签到调度：每小时 tick，本地时间到点当日未签则执行。
  void _scheduleCheckin() {
    _checkinTimer?.cancel();
    _checkinTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      if (!_checkinEnabled) return;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      if (now.hour * 60 + now.minute < _checkinHour * 60 + _checkinMinute) return;
      if (_lastCheckinDay == today) return;
      _lastCheckinDay = today;
      for (final acc in _accounts) {
        await doCheckin(acc);
      }
      await refreshCredits();
    });
  }

  /// 服务关闭时的清理（延时兜底的定时器随 isolate 退出自动回收）。
  void dispose() {
    _checkinTimer?.cancel();
    for (final t in _leaseTimers.values) {
      t.cancel();
    }
    _leaseTimers.clear();
    _client.close();
  }
}
