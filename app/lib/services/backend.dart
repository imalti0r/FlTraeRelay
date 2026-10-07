// backend.dart - 全局应用状态：进程内启动 RelayServer（HTTP + 账号池 + 模型目录），
// 读写 config.json 与 usage 记录，向 UI 提供状态刷新与签到/积分操作。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/account_pool.dart';
import '../core/auth.dart' show Account;
import '../core/model_catalog.dart';
import '../core/relay_server.dart';
import '../core/storage.dart' show detectIdeVersion;
import '../models.dart';

enum BackendState { stopped, starting, running }

/// 编译期兜底版本头（与 C++ Config::resolveIdeVersion 的 kFallbackIdeVersion 一致）。
const String _fallbackIdeVersion = '3.3.102';
const String _fallbackIdeVersionCode = '20260916';

/// UI 视图模型（与 core 层解耦）。
class AccountView {
  AccountView._(Account a, {required this.disabled})
      : nickname = a.nickname,
        edition = a.editionId,
        credits = a.credits,
        active = a.active,
        expiredTs = a.expiredTs,
        id = a.id;
  final String nickname;
  final String edition;
  final double credits;
  final int active;
  final int expiredTs;
  final String id;
  final bool disabled;
  bool get busy => active > 0;

  /// 到期时间（未知返回 null）。
  DateTime? get expiredDate =>
      expiredTs == 0 ? null : DateTime.fromMillisecondsSinceEpoch(expiredTs * 1000);
}

class UsageRow {
  UsageRow._(UsageRecord r)
      : ts = r.ts,
        account = r.account,
        model = r.model,
        endpoint = r.endpoint,
        input = r.input,
        output = r.output,
        creditsDelta = r.creditsDelta,
        creditsKnown = r.creditsKnown,
        ms = r.ms,
        ok = r.ok,
        _source = r;
  final UsageRecord _source;
  final DateTime ts;
  final String account;
  final String model;
  final String endpoint;
  final int input;
  final int output;
  final double creditsDelta;
  final bool creditsKnown;
  final int ms;
  final bool ok;
  int get tokens => input + output;
}

class ModelCatalogView {
  const ModelCatalogView({
    required this.id,
    required this.displayName,
    required this.maxMode,
    required this.effortOptions,
    required this.effortDefault,
    required this.supportThinking,
    required this.vision,
    required this.cwDefault,
    required this.cwMax,
    required this.rateBase,
    required this.rateActivity,
    required this.activityType,
  });
  final String id;
  final String displayName;
  final bool maxMode;
  final List<String> effortOptions;
  final String effortDefault;
  final bool supportThinking;
  final bool vision;
  final int cwDefault;
  final List<int> cwMax;
  final double rateBase;
  final double rateActivity;
  final String activityType;
  String get label => displayName.isEmpty ? id : displayName;

  /// 展示用的计费倍率：活动价优先（现价），否则基础倍率。
  String? get rateLabel {
    final r = rateActivity > 0 ? rateActivity : rateBase;
    if (r <= 0) return null;
    return r.toString();
  }
}

class AppState extends ChangeNotifier {
  BackendState state = BackendState.stopped;
  String? notice;

  RelayConfig? config;
  bool configDirty = false; // 配置已修改、服务尚未按新配置重启

  RelayServer? _server;

  /// 与原生托盘层的通道（exitApp / setEnabled）。
  static const MethodChannel trayChannel = MethodChannel('fltrae_relay/tray');
  AccountPool? _pool;
  ModelCatalog? _catalog;
  Timer? _pollTimer;
  StreamSubscription<FileSystemEvent>? _configWatchSub;
  Timer? _configReloadDebounce;
  String _configSignature = '';

  /// 数据目录：%APPDATA%\FlTraeRelay（config.json、accounts/ 账号快照、
  /// usage/ 使用记录都落在这里）。APPDATA 不可用时退回 exe 同目录。
  String get dataDir {
    final appData = Platform.environment['APPDATA'] ?? '';
    if (appData.length > 3) {
      try {
        final dir = '$appData\\FlTraeRelay';
        Directory(dir).createSync(recursive: true);
        return dir;
      } catch (_) {
        // AppData 不可写：退回 exe 同目录
      }
    }
    return File(Platform.resolvedExecutable).parent.path;
  }

  String get configPath => '$dataDir\\config.json';
  bool get backendRunning => state == BackendState.running;

  // ---------- 生命周期 ----------

  Future<void> init() async {
    await _loadConfig();
    await startBackend();
    _watchConfigFile();
  }

  Future<void> _loadConfig() async {
    try {
      final f = File(configPath);
      if (f.existsSync()) {
        final decoded = jsonDecode(f.readAsStringSync());
        config = RelayConfig(decoded is Map<String, dynamic> ? decoded : <String, dynamic>{});
      } else {
        config = RelayConfig(<String, dynamic>{});
        // 首次运行：生成 API Key 并写盘（与 C++ 首启行为一致）
        config!.apiKey = RelayConfig.genApiKey();
        await saveConfig(silent: true);
      }
      _configSignature = jsonEncode(config!.raw);
    } catch (e) {
      config = RelayConfig(<String, dynamic>{});
      notice = '配置读取失败，已使用默认配置：$e';
    }
  }

  // ---------- 配置热加载 ----------

  /// 监视 config.json：外部编辑保存后自动重载并热应用到运行中的服务，
  /// 无需重启程序。程序自己 saveConfig 写盘触发的事件经签名比对短路。
  void _watchConfigFile() {
    try {
      _configWatchSub = Directory(dataDir).watch(events: FileSystemEvent.all).listen((event) {
        if (!event.path.endsWith('config.json')) return;
        _configReloadDebounce?.cancel();
        _configReloadDebounce =
            Timer(const Duration(milliseconds: 800), _reloadConfigIfChanged);
      }, onError: (_) {});
    } catch (_) {
      // 目录监视不可用：退回旧行为（改配置需重启）
    }
  }

  Future<void> _reloadConfigIfChanged() async {
    try {
      final f = File(configPath);
      if (!f.existsSync()) return;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return;
      final sig = jsonEncode(decoded);
      if (sig == _configSignature) return; // 自己保存的写盘事件，跳过
      _configSignature = sig;
      await _applyHotConfig(decoded);
    } catch (_) {
      // 半截写入或非法 JSON：忽略，等下一次保存事件
    }
  }

  /// 把新配置热应用到运行中的 pool / server。仅 host/port/allowLan 变化时重绑端口。
  Future<void> _applyHotConfig(Map<String, dynamic> raw) async {
    final old = config;
    final cfg = RelayConfig(raw);
    if (cfg.apiKey.isEmpty) cfg.apiKey = old?.apiKey ?? RelayConfig.genApiKey();
    // IDE 版本头是启动时从本机 Trae 探测的，不落盘，热加载时继承
    cfg.ideVersion = old?.ideVersion ?? '';
    cfg.ideVersionCode = old?.ideVersionCode ?? '';
    config = cfg;

    _pool?.updateSettings(
      maxConcurrentPerAccount: cfg.maxConcurrentPerAccount,
      minRequestIntervalMs: 0,
      poolSelectBy: cfg.poolSelectBy,
      ideVersion: cfg.ideVersion,
      ideVersionCode: cfg.ideVersionCode,
      checkinEnabled: cfg.checkinEnabled,
      checkinHour: cfg.checkinHour,
      checkinMinute: cfg.checkinMinute,
      disabledAccountIds: cfg.disabledAccounts.toSet(),
      deletedAccountIds: cfg.deletedAccounts.toSet(),
    );

    final server = _server;
    if (server != null) {
      final next = _settingsFrom(cfg);
      final rebind = server.settings.port != next.port ||
          server.settings.host != next.host ||
          server.settings.allowLan != next.allowLan;
      server.settings = next;
      if (rebind) {
        try {
          await server.stop();
          await server.start();
          notice = null;
        } catch (e) {
          notice = '配置已热加载，但监听 ${next.host}:${cfg.servicePort} 失败：$e';
        }
      }
    }
    configDirty = false;
    unawaited(pushTraySetting());
    notifyListeners();
  }

  Future<void> startBackend() async {
    final cfg = config;
    if (cfg == null || state == BackendState.starting || backendRunning) return;
    state = BackendState.starting;
    notice = null;
    notifyListeners();

    try {
      // IDE 版本头：从本机 Trae 安装探测，失败用编译期兜底（与 C++ 行为一致）
      final (ver, code) = detectIdeVersion() ?? (_fallbackIdeVersion, _fallbackIdeVersionCode);
      cfg.ideVersion = ver;
      cfg.ideVersionCode = code;

      final pool = AccountPool(dataDir);
      pool.autoDiscover();
      pool.updateSettings(
        maxConcurrentPerAccount: cfg.maxConcurrentPerAccount,
        minRequestIntervalMs: 0,
        poolSelectBy: cfg.poolSelectBy,
        ideVersion: ver,
        ideVersionCode: code,
        checkinEnabled: cfg.checkinEnabled,
        checkinHour: cfg.checkinHour,
        checkinMinute: cfg.checkinMinute,
        disabledAccountIds: cfg.disabledAccounts.toSet(),
        deletedAccountIds: cfg.deletedAccounts.toSet(),
      );
      final catalog = ModelCatalog();
      catalog.bind(pool);
      final server = RelayServer(pool: pool, catalog: catalog, settings: _settingsFrom(cfg));
      server.trayChannel = trayChannel;
      _registerDebugHandlers(server);
      await server.start();

      _pool = pool;
      _catalog = catalog;
      _server = server;
      state = BackendState.running;
      configDirty = false;
      notifyListeners();

      // 服务启动即提供真实积分（与 C++ --serve 行为一致），随后启动模型目录定时刷新
      unawaited(pool.refreshCredits().then((_) {
        catalog.start();
        notifyListeners();
      }));
      _startPolling();
      // 原生托盘开关是进程级状态：每次启动后按配置重新推送
      unawaited(pushTraySetting());
    } catch (e) {
      state = BackendState.stopped;
      notice = '服务启动失败：$e（端口 ${cfg.servicePort} 可能被占用）';
      notifyListeners();
    }
  }

  /// 把"关闭最小化到托盘"开关推送到原生托盘层（启动与设置变更时调用）。
  Future<void> pushTraySetting() async {
    final cfg = config;
    if (cfg == null) return;
    try {
      await trayChannel.invokeMethod<bool>('setEnabled', cfg.closeToTray);
    } on MissingPluginException {
      // 非 Windows 平台或通道未就绪：忽略
    } catch (_) {}
  }

  /// 注册调试 API 处理器（/v1/debug/*，需 API Key）。
  void _registerDebugHandlers(RelayServer server) {
    server.debugGetters = {
      // 当前 config.json（apiKey 打码）
      'config': () {
        final raw = <String, dynamic>{...?config?.raw};
        final svc = raw['service'];
        if (svc is Map) {
          final key = svc['apiKey'];
          if (key is String && key.length > 12) {
            svc['apiKey'] = '${key.substring(0, 10)}***';
          }
        }
        return raw;
      },
      // 模型目录细节
      'models': () => {
            'models': [
              for (final m in modelCatalogViews)
                {
                  'id': m.id,
                  'displayName': m.displayName,
                  'maxMode': m.maxMode,
                  'supportThinking': m.supportThinking,
                  'effortOptions': m.effortOptions,
                  'effortDefault': m.effortDefault,
                  'vision': m.vision,
                  'contextWindow': m.cwDefault,
                  'rate': m.rateLabel,
                }
            ],
          },
    };

    server.debugHandlers = {
      // 全账号签到
      'checkin': (_) async => {'ok': await checkinAll()},
      // 刷新积分
      'refresh-credits': (_) async {
        await refreshCreditsAll();
        return {'ok': true, 'accounts': [for (final a in accountViews) {'nickname': a.nickname, 'credits': a.credits}]};
      },
      // 回显（连通性测试）
      'echo': (args) async => {'echo': args, 'time': DateTime.now().toIso8601String()},
      // 账号管理：停用/启用/删除/恢复，参数 {"id": "solo:1234"}
      'account-disable': (args) async {
        final id = args['id']?.toString() ?? '';
        if (id.isEmpty) return {'ok': false, 'error': '缺少 id'};
        await setAccountDisabled(id, true);
        return {'ok': true};
      },
      'account-enable': (args) async {
        final id = args['id']?.toString() ?? '';
        if (id.isEmpty) return {'ok': false, 'error': '缺少 id'};
        await setAccountDisabled(id, false);
        return {'ok': true};
      },
      'account-delete': (args) async {
        final id = args['id']?.toString() ?? '';
        if (id.isEmpty) return {'ok': false, 'error': '缺少 id'};
        await deleteAccount(id);
        return {'ok': true};
      },
      'account-restore': (args) async {
        final id = args['id']?.toString() ?? '';
        if (id.isEmpty) return {'ok': false, 'error': '缺少 id'};
        await restoreAccount(id);
        return {'ok': true, 'accounts': [for (final a in accountViews) a.id]};
      },
      // 已删除账号列表
      'accounts-deleted': (_) async => {'deleted': deletedAccountIds},
      // 触发托盘退出链路（与托盘菜单"退出"等价）：仅调试用
      'tray-exit': (_) async {
        try {
          await server.trayChannel?.invokeMethod<bool>('exitApp');
          return {'ok': true, 'note': 'exitApp 已发送，进程应随即退出'};
        } catch (e) {
          return {'ok': false, 'error': '$e'};
        }
      },
    };
  }

  RelaySettings _settingsFrom(RelayConfig cfg) {
    return RelaySettings()
      ..host = cfg.serviceHost
      ..port = cfg.servicePort
      ..allowLan = cfg.allowLan
      ..apiKey = cfg.apiKey
      ..allowAnyApiKey = cfg.allowAnyApiKey
      ..defaultStream = cfg.stream
      ..defaultReasoningEffort = cfg.reasoningEffort ?? ''
      ..defaultIsMaxMode = cfg.isMaxMode
      ..defaultMaxContextWindow = 0
      ..ideVersion = cfg.ideVersion
      ..ideVersionCode = cfg.ideVersionCode
      ..logLevel = cfg.logLevel
      ..loggingEnabled = cfg.loggingEnabled;
  }

  Future<void> stopBackend() async {
    _stopPolling();
    final server = _server;
    _server = null;
    _catalog?.stop();
    _catalog = null;
    _pool = null;
    state = BackendState.stopped;
    notifyListeners();
    await server?.stop();
  }

  /// 按当前 config.json 重启服务（改配置后调用）。
  Future<void> restartBackend() async {
    await stopBackend();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await startBackend();
  }

  // ---------- 数据刷新 ----------

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => refreshOnce());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 读取一条使用记录的详情（请求消息与回复内容）。
  Map<String, dynamic>? readDetail(UsageRow row) => _pool?.readDetail(row._source);

  // ---------- 账号管理 ----------

  /// 停用 / 启用账号（写配置并同步池子调度）。
  Future<void> setAccountDisabled(String id, bool disabled) async {
    config?.setAccountDisabled(id, disabled);
    if (disabled) {
      _pool?.disableAccount(id);
    } else {
      _pool?.enableAccount(id);
    }
    await saveConfig();
  }

  /// 删除账号（写删除表、从池移除；重新发现不再加入）。
  Future<void> deleteAccount(String id) async {
    config?.deleteAccount(id);
    _pool?.removeAccount(id);
    await saveConfig();
  }

  /// 恢复已删除的账号（重新扫描登录态并入池，并同步停用表）。
  Future<void> restoreAccount(String id) async {
    config?.restoreAccount(id);
    _pool?.autoDiscover(force: true);
    for (final d in config?.disabledAccounts ?? const <String>[]) {
      _pool?.disableAccount(d);
    }
    notifyListeners();
  }

  /// 已删除的账号 id 列表（UI 展示"恢复"入口用）。
  List<String> get deletedAccountIds => config?.deletedAccounts ?? const [];

  /// 进程内数据已在 AccountPool 上，这里刷新今日统计并通知 UI。
  Future<void> refreshOnce() async {
    if (!backendRunning) return;
    _pool?.usageToday();
    notifyListeners();
  }

  // ---------- 账号操作（进程内直调） ----------

  List<AccountView> get accountViews {
    final pool = _pool;
    if (pool == null) return const [];
    return [
      for (final a in pool.accounts)
        AccountView._(a, disabled: pool.isDisabled(a.id)),
    ];
  }

  Future<bool> checkinAll() async {
    final pool = _pool;
    if (pool == null) return false;
    var anyOk = false;
    for (final acc in pool.accounts) {
      final r = await pool.doCheckin(acc);
      if (r >= 0) anyOk = true;
    }
    await pool.refreshCredits();
    refreshOnce();
    return anyOk;
  }

  Future<void> refreshCreditsAll() async {
    await _pool?.refreshCredits();
    refreshOnce();
  }

  TodayUsage get todayUsage => _pool?.usageToday() ?? TodayUsage();

  /// 主题模式名（system / light / dark），持久化在 config.json 的 ui 节。
  String get themeModeName {
    final v = config?.themeMode ?? 'system';
    return (v == 'light' || v == 'dark') ? v : 'system';
  }

  void setThemeModeName(String v) {
    final c = config;
    if (c == null) return;
    c.themeMode = v;
    saveConfig(silent: true);
  }

  List<UsageRow> usageForDay(DateTime day) {
    final pool = _pool;
    if (pool == null) return const [];
    return [for (final r in pool.usagePage(day)) UsageRow._(r)];
  }

  /// 手动触发模型目录刷新。
  Future<void> refreshModels() async {
    final pool = _pool;
    final catalog = _catalog;
    if (pool == null || catalog == null || pool.accounts.isEmpty) return;
    await catalog.refreshOnce(pool.accounts.first);
    notifyListeners();
  }

  List<ModelCatalogView> get modelCatalogViews {
    final catalog = _catalog;
    if (catalog == null) return const [];
    return [
      for (final c in catalog.cached)
        ModelCatalogView(
          id: c.configName,
          displayName: c.displayName.isEmpty ? c.configName : c.displayName,
          maxMode: c.maxMode,
          effortOptions: [...c.effortOptions, ...c.effortOptionsExt],
          effortDefault: c.effortDefault,
          supportThinking: c.supportThinking,
          vision: c.vision,
          cwDefault: c.cwDefault,
          cwMax: c.cwMax,
          rateBase: c.rateBase,
          rateActivity: c.rateActivity,
          activityType: c.activityType,
        )
    ];
  }

  // ---------- 配置写入 ----------

  Future<bool> saveConfig({bool silent = false}) async {
    final cfg = config;
    if (cfg == null) return false;
    try {
      const encoder = JsonEncoder.withIndent('  ');
      final tmp = '$configPath.${DateTime.now().microsecondsSinceEpoch}.tmp';
      final t = File(tmp);
      t.writeAsStringSync(encoder.convert(cfg.raw));
      final f = File(configPath);
      if (f.existsSync()) f.deleteSync();
      t.renameSync(f.path);
      configDirty = backendRunning && !silent;
      if (!silent) notice = null;
      notifyListeners();
      return true;
    } catch (e) {
      notice = '保存配置失败：$e';
      notifyListeners();
      return false;
    }
  }

  Future<void> regenerateApiKey() async {
    final cfg = config;
    if (cfg == null) return;
    cfg.apiKey = RelayConfig.genApiKey();
    await saveConfig();
  }

  void markConfigChanged() {
    configDirty = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopPolling();
    _configReloadDebounce?.cancel();
    _configWatchSub?.cancel();
    _server?.stop();
    _catalog?.stop();
    _pool?.dispose();
    super.dispose();
  }
}
