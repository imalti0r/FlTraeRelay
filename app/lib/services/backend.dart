// backend.dart - 全局应用状态：以 sidecar 方式管理官方 TraeRelay.exe --serve
// 进程，轮询 /health 与 /v1/status，读写 config.json 与 usage 记录。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'config_store.dart';
import 'relay_api.dart';
import 'usage_store.dart';

enum BackendState { exeMissing, stopped, starting, running }

class AppState extends ChangeNotifier {
  static const _prefExePath = 'backend.exePath';
  static const exeName = 'TraeRelay.exe';

  String? exePath;
  BackendState state = BackendState.exeMissing;
  String? notice;

  RelayConfig? config;
  bool configDirty = false; // 配置已修改、后端尚未按新配置重启

  List<ModelInfo> models = [];
  List<AccountInfo> accounts = [];
  TodayUsage today = TodayUsage(requests: 0, tokens: 0, credits: 0);

  RelayApi? _api;
  Process? _process;
  Timer? _pollTimer;
  StreamSubscription? _exitSub;
  SharedPreferences? _prefs;

  UsageStore? get usage => exePath == null ? null : UsageStore(exePath!);
  ConfigStore? get configStore =>
      exePath == null ? null : ConfigStore(ConfigStore.configPathFor(exePath!));

  bool get backendRunning => state == BackendState.running;

  // ---------- 初始化 ----------

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    exePath = _prefs?.getString(_prefExePath);
    if (exePath == null || !File(exePath!).existsSync()) {
      exePath = await _discoverExe();
    }
    await _loadConfig();
    if (exePath != null) {
      state = BackendState.stopped;
    }
    notifyListeners();
  }

  /// 默认在 Flutter 应用 exe 同目录寻找 TraeRelay.exe（打包分发时两者放一起）。
  Future<String?> _discoverExe() async {
    final dir = File(Platform.resolvedExecutable).parent;
    final candidate = File('${dir.path}${Platform.pathSeparator}$exeName');
    return candidate.existsSync() ? candidate.path : null;
  }

  Future<void> _loadConfig() async {
    final store = configStore;
    if (store == null) {
      config = null;
      return;
    }
    config = await store.load();
  }

  Future<void> setExePath(String path) async {
    final f = File(path.trim());
    if (!f.existsSync()) {
      notice = '文件不存在：$path';
      notifyListeners();
      return;
    }
    exePath = f.path;
    await _prefs?.setString(_prefExePath, f.path);
    notice = null;
    state = BackendState.stopped;
    await _loadConfig();
    notifyListeners();
  }

  // ---------- 后端进程管理 ----------

  Future<void> startBackend() async {
    if (exePath == null || state == BackendState.starting || backendRunning) return;
    final exe = exePath!;
    state = BackendState.starting;
    notice = null;
    notifyListeners();

    try {
      final proc = await Process.start(
        exe,
        const ['--serve'],
        workingDirectory: File(exe).parent.path,
        mode: ProcessStartMode.detachedWithStdio,
      );
      _process = proc;
      _exitSub = proc.exitCode.then((code) {
        _onBackendExited(code);
      });
    } catch (e) {
      state = BackendState.stopped;
      notice = '启动失败：$e';
      notifyListeners();
      return;
    }

    // 等待 /health 就绪；进程提前退出（如单实例互斥命中）时立即结束等待。
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (_process == null) return; // 已退出，_onBackendExited 已更新状态
      if (await _currentApi().health()) {
        state = BackendState.running;
        configDirty = false;
        notice = null;
        await refreshOnce();
        _startPolling();
        notifyListeners();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    state = BackendState.stopped;
    notice = '后端未在 20 秒内就绪，请检查端口占用或查看 logs/ 目录';
    notifyListeners();
  }

  void _onBackendExited(int code) {
    _process = null;
    _exitSub = null;
    _stopPolling();
    if (state == BackendState.starting) {
      notice = '后端进程立即退出（退出码 $code）。'
          '若已有一个 Trae Relay 实例在运行（单实例互斥），请先退出它再启动。';
    } else if (state == BackendState.running) {
      notice = '后端进程已退出（退出码 $code）';
    }
    state = exePath == null ? BackendState.exeMissing : BackendState.stopped;
    accounts = [];
    notifyListeners();
  }

  Future<void> stopBackend() async {
    final proc = _process;
    _stopPolling();
    state = BackendState.stopped;
    notice = null;
    accounts = [];
    notifyListeners();
    if (proc != null) {
      _process = null;
      proc.kill();
      // detachedWithStdio 下等待退出事件完成状态收敛
      await proc.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    }
  }

  /// 按当前 config.json 重启后端（改配置后调用）。
  Future<void> restartBackend() async {
    await stopBackend();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await startBackend();
  }

  // ---------- 数据刷新 ----------

  RelayApi _currentApi() {
    final cfg = config;
    final api = RelayApi(
      host: cfg?.serviceHost ?? '127.0.0.1',
      port: cfg?.servicePort ?? 8317,
      apiKey: cfg?.apiKey ?? '',
    );
    _api = api;
    return api;
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      refreshOnce();
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 拉取状态、模型与今日用量。失败静默（轮询场景），成功后通知 UI。
  Future<void> refreshOnce() async {
    if (!backendRunning) return;
    final api = _currentApi();
    try {
      final status = await api.status();
      accounts = status.accounts;
      if (models.isEmpty) {
        try {
          models = await api.models();
        } catch (_) {}
      }
      final u = usage;
      if (u != null) {
        today = await u.usageFor(DateTime.now());
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> refreshModels() async {
    if (!backendRunning) return;
    try {
      models = await _currentApi().models();
      notifyListeners();
    } catch (_) {}
  }

  // ---------- 配置写入 ----------

  Future<bool> saveConfig() async {
    final store = configStore;
    final cfg = config;
    if (store == null || cfg == null) return false;
    try {
      await store.save(cfg);
      configDirty = backendRunning;
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

  /// 标记配置被 UI 修改（由各设置控件调用，保存统一走 saveConfig）。
  void markConfigChanged() {
    configDirty = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopPolling();
    _exitSub?.cancel();
    _process?.kill();
    super.dispose();
  }
}
