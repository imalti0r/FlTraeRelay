// settings_page.dart - 偏好设置：服务、账号池、签到、Responses 缓存、日志。
// 修改写入 config.json；需要"保存并重启后端"才对运行中的服务生效。

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../models.dart';
import '../services/backend.dart';
import '../widgets.dart';

/// 账号选择策略与日志级别的取值序列（分段控件按索引映射）。
const _poolStrategies = ['credits', 'expiry', 'roundRobin'];
const _poolStrategyLabels = ['余额优先', '到期优先', '轮询'];
const _logLevels = ['trace', 'debug', 'info', 'warn', 'error'];

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.app});

  final AppState app;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _port;
  late final TextEditingController _concurrency;
  late final TextEditingController _cacheSize;
  late final TextEditingController _retainDays;
  late final TextEditingController _checkinHour;
  late final TextEditingController _checkinMinute;

  RelayConfig get cfg => widget.app.config!;

  @override
  void initState() {
    super.initState();
    _port = TextEditingController(text: '${cfg.servicePort}');
    _concurrency = TextEditingController(text: '${cfg.maxConcurrentPerAccount}');
    _cacheSize = TextEditingController(text: '${cfg.sessionCacheSize}');
    _retainDays = TextEditingController(text: '${cfg.logRetainDays}');
    _checkinHour = TextEditingController(text: '${cfg.checkinHour}');
    _checkinMinute = TextEditingController(text: '${cfg.checkinMinute}');
  }

  @override
  void dispose() {
    _port.dispose();
    _concurrency.dispose();
    _cacheSize.dispose();
    _retainDays.dispose();
    _checkinHour.dispose();
    _checkinMinute.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 60, 20, 100),
      children: [
        _appearanceCard(context),
        _serviceCard(context),
        _accountCard(context),
        _cacheCard(context),
        _loggingCard(context),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(
              onPressed: _save,
              child: const Text('保存'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: widget.app.backendRunning ? _saveAndRestart : null,
              icon: const Icon(Icons.restart_alt),
              label: const Text('保存并重启后端'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '配置写入后端 exe 同目录的 config.json；端口、并发等运行参数在后端重启后生效。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  int? _parseInt(String s, int min, int max) {
    final v = int.tryParse(s.trim());
    if (v == null || v < min || v > max) return null;
    return v;
  }

  Future<void> _save() async {
    final port = _parseInt(_port.text, 1, 65535);
    final concurrency = _parseInt(_concurrency.text, 1, 8);
    final cacheSize = _parseInt(_cacheSize.text, 1, 4096);
    final retainDays = _parseInt(_retainDays.text, 1, 365);
    final hour = _parseInt(_checkinHour.text, 0, 23);
    final minute = _parseInt(_checkinMinute.text, 0, 59);
    final errors = <String>[
      if (port == null) '端口需为 1～65535',
      if (concurrency == null) '每账号并发需为 1～8',
      if (cacheSize == null) '会话缓存数量需为正整数',
      if (retainDays == null) '日志保留天数需为 1～365',
      if (hour == null || minute == null) '签到时间格式不正确',
    ];
    if (errors.isNotEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errors.join('；'))));
      return;
    }
    cfg.servicePort = port!;
    cfg.maxConcurrentPerAccount = concurrency!;
    cfg.sessionCacheSize = cacheSize!;
    cfg.logRetainDays = retainDays!;
    cfg.checkinHour = hour!;
    cfg.checkinMinute = minute!;
    final ok = await widget.app.saveConfig();
    if (!mounted) return;
    if (ok) showConfigSaved(context, backendRunning: widget.app.backendRunning);
  }

  Future<void> _saveAndRestart() async {
    await _save();
    await widget.app.restartBackend();
  }

  // ---------- 各分组卡片 ----------

  /// 外观：主题模式（跟随系统 / 浅色 / 深色），持久化到 config.json。
  Widget _appearanceCard(BuildContext context) {
    const names = ['system', 'light', 'dark'];
    const labels = ['跟随系统', '浅色', '深色'];
    final current = widget.app.themeModeName;
    final index = names.indexOf(current) < 0 ? 0 : names.indexOf(current);
    return SectionCard(title: '外观', children: [
      GlassSegmentedControl(
        segments: [for (final l in labels) GlassSegment(label: l)],
        selectedIndex: index,
        onSegmentSelected: (i) =>
            setState(() => widget.app.setThemeModeName(names[i])),
      ),
    ]);
  }

  Widget _serviceCard(BuildContext context) {
    return SectionCard(title: '服务', children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _numberField('端口', _port)),
          const SizedBox(width: 16),
          Expanded(child: _numberField('每账号并发数（1～8）', _concurrency)),
        ],
      ),
      const SizedBox(height: 12),
      _switchRow('局域网访问', '监听 0.0.0.0，允许局域网内其他设备调用（请在可信网络使用）', cfg.allowLan,
          (v) => setState(() => cfg.allowLan = v)),
      const SizedBox(height: 12),
      _switchRow('默认流式输出', '客户端未显式传 stream 时的默认值', cfg.stream, (v) => setState(() => cfg.stream = v)),
      const SizedBox(height: 12),
      _switchRow('自动续跑', '回答被截断时自动继续（autoContinue）', cfg.autoContinue,
          (v) => setState(() => cfg.autoContinue = v)),
      const SizedBox(height: 12),
      _switchRow('关闭软件时最小化到托盘', '点关闭按钮时隐藏到系统托盘，HTTP 服务继续运行；从托盘菜单可真正退出',
          cfg.closeToTray, (v) => setState(() => cfg.closeToTray = v)),
    ]);
  }

  Widget _accountCard(BuildContext context) {
    final strategyIndex = _poolStrategies.indexOf(cfg.poolSelectBy);
    return SectionCard(title: '账号与签到', children: [
      _switchRow('自动发现账号', '启动时扫描当前 Windows 用户已登录的 Trae', cfg.accountsAutoDiscover,
          (v) => setState(() => cfg.accountsAutoDiscover = v)),
      const SizedBox(height: 12),
      _switchRow('自动签到', '每日到点自动为发现的账号签到，限流时自动退避重试',
          cfg.checkinEnabled, (v) => setState(() => cfg.checkinEnabled = v)),
      const SizedBox(height: 12),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _numberField('签到时间 · 时（0～23）', _checkinHour)),
          const SizedBox(width: 16),
          Expanded(child: _numberField('签到时间 · 分（0～59）', _checkinMinute)),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 8,
        children: [
          const Text('账号选择策略'),
          GlassSegmentedControl(
            segments: [
              for (final label in _poolStrategyLabels) GlassSegment(label: label),
            ],
            selectedIndex: strategyIndex < 0 ? 0 : strategyIndex,
            onSegmentSelected: (i) => setState(() => cfg.poolSelectBy = _poolStrategies[i]),
          ),
        ],
      ),
    ]);
  }

  Widget _cacheCard(BuildContext context) {
    return SectionCard(title: 'Responses', children: [
      _numberField('会话缓存数量', _cacheSize),
      const SizedBox(height: 12),
      _switchRow('持久化会话缓存', '保存 previous_response_id 对应的文本与工具历史到磁盘',
          cfg.sessionCachePersist, (v) => setState(() => cfg.sessionCachePersist = v)),
    ]);
  }

  Widget _loggingCard(BuildContext context) {
    final levelIndex = _logLevels.indexOf(cfg.logLevel);
    return SectionCard(title: '日志', children: [
      _switchRow('启用日志', '关闭后不再写 logs/ 目录', cfg.loggingEnabled, (v) => setState(() => cfg.loggingEnabled = v)),
      const SizedBox(height: 12),
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 8,
        children: [
          const Text('日志级别'),
          GlassSegmentedControl(
            segments: const [
              GlassSegment(label: 'Trace'),
              GlassSegment(label: 'Debug'),
              GlassSegment(label: 'Info'),
              GlassSegment(label: 'Warn'),
              GlassSegment(label: 'Error'),
            ],
            selectedIndex: levelIndex < 0 ? 2 : levelIndex,
            onSegmentSelected: (i) => setState(() => cfg.logLevel = _logLevels[i]),
          ),
        ],
      ),
      const SizedBox(height: 12),
      _numberField('日志保留天数（1～365）', _retainDays),
    ]);
  }

  // ---------- 行组件 ----------

  /// 数字输入项：标签在输入框上方（floating label 风格），避免长标签挤压布局。
  Widget _numberField(String label, TextEditingController controller) {
    return SizedBox(
      width: 240,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }

  Widget _switchRow(String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        GlassSwitch(
          value: value,
          activeColor: Theme.of(context).colorScheme.primary,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
