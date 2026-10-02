// overview.dart - 运行总览：服务控制、账号与积分、今日用量、本地端点。
// 模型列表与模型设置已独立到 models_page.dart。

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/backend.dart';
import '../widgets.dart';

class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key, required this.app});

  final AppState app;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  bool _checkinBusy = false;

  @override
  void dispose() {
    super.dispose();
  }

  AppState get app => widget.app;
  RelayConfig? get cfg => app.config;

  Future<void> _apply(Future<void> Function() mutate) async {
    await mutate();
    final ok = await app.saveConfig();
    if (!mounted) return;
    if (ok) showConfigSaved(context, backendRunning: app.backendRunning);
  }

  @override
  Widget build(BuildContext context) {
    final config = cfg;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _backendCard(context),
        if (config == null)
          const SizedBox.shrink()
        else ...[
          _accountCard(context),
          _todayStats(context),
          _endpointCard(context, config),
        ],
      ],
    );
  }

  // ---------- 服务控制 ----------

  Widget _backendCard(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color, icon) = switch (app.state) {
      BackendState.running => ('运行中', theme.colorScheme.primary, Icons.play_circle_fill),
      BackendState.starting => ('启动中', theme.colorScheme.tertiary, Icons.autorenew),
      BackendState.stopped => ('已停止', theme.colorScheme.onSurfaceVariant, Icons.stop_circle_outlined),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('后端服务', style: theme.textTheme.titleMedium),
                const SizedBox(width: 12),
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 6),
                Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
                const Spacer(),
                TextButton(
                  onPressed: app.state == BackendState.starting ? null : () => app.startBackend(),
                  child: const Text('启动'),
                ),
                TextButton(
                  onPressed: app.state == BackendState.stopped ? null : () => app.restartBackend(),
                  child: const Text('重启'),
                ),
                TextButton(
                  onPressed: app.backendRunning ? () => app.stopBackend() : null,
                  child: const Text('停止'),
                ),
              ],
            ),
            if (app.notice != null) ...[
              const SizedBox(height: 8),
              Text(app.notice!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            ],
            if (app.backendRunning) ...[
              const SizedBox(height: 8),
              Text(
                'OpenAI 兼容端点已监听 ${app.config?.baseUrl ?? ''}，客户端可直接接入',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------- 账号 ----------

  Widget _accountCard(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = app.accountViews;
    return SectionCard(
      title: '当前账号',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: _checkinBusy ? null : _checkinNow,
            icon: _checkinBusy
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.verified_outlined, size: 18),
            label: const Text('立即签到'),
          ),
          IconButton(
            tooltip: '刷新积分',
            icon: const Icon(Icons.refresh),
            onPressed: app.backendRunning ? () => app.refreshCreditsAll() : null,
          ),
        ],
      ),
      children: [
        if (accounts.isEmpty)
          Text(
            app.backendRunning
                ? '暂未发现账号：请确认当前 Windows 用户已登录 Trae，然后重启服务'
                : '服务未运行，启动后自动发现账号',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          )
        else
          ...accounts.map(_accountTile),
      ],
    );
  }

  Future<void> _checkinNow() async {
    setState(() => _checkinBusy = true);
    final ok = await app.checkinAll();
    if (!mounted) return;
    setState(() => _checkinBusy = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(ok ? '签到完成' : '签到失败，请查看日志')));
  }

  Widget _accountTile(AccountView a) {
    final theme = Theme.of(context);
    final color = a.disabled
        ? theme.colorScheme.outline
        : (a.busy ? theme.colorScheme.tertiary : theme.colorScheme.primary);
    // 到期提示：7 天内临近到期标橙，已到期标红
    final expired = a.expiredDate;
    String? expiryText;
    Color? expiryColor;
    if (expired != null && !a.disabled) {
      final remain = expired.difference(DateTime.now());
      final two = (int n) => n.toString().padLeft(2, '0');
      expiryText =
          '到期 ${expired.year}-${two(expired.month)}-${two(expired.day)}';
      if (remain.inDays < 0) {
        expiryColor = theme.colorScheme.error;
        expiryText = '已到期 · $expiryText';
      } else if (remain.inDays < 7) {
        expiryColor = theme.colorScheme.tertiary;
        expiryText = '$expiryText（剩 ${remain.inDays + 1} 天）';
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Opacity(
              opacity: a.disabled ? 0.45 : 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.nickname, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        a.disabled
                            ? '已停用'
                            : (a.busy
                                ? '忙碌（${a.active} 个并发请求）'
                                : '正常'),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: a.disabled
                                ? theme.colorScheme.outline
                                : theme.colorScheme.onSurfaceVariant),
                      ),
                      if (expiryText != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          expiryText,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: expiryColor ??
                                  theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          // 启用/停用
          Tooltip(
            message: a.disabled ? '启用该账号' : '停用该账号（调度跳过）',
            child: Switch(
              value: !a.disabled,
              onChanged: (on) =>
                  widget.app.setAccountDisabled(a.id, !on),
            ),
          ),
          // 删除 / 恢复
          IconButton(
            tooltip: a.disabled ? '删除该账号（可从已删除列表恢复）' : '先停用后才能删除',
            icon: Icon(
              Icons.delete_outline,
              color: a.disabled ? theme.colorScheme.error : null,
            ),
            onPressed: a.disabled
                ? () => _confirmDelete(a)
                : null,
          ),
          Chip(
            avatar: Icon(Icons.workspace_premium_outlined,
                size: 16, color: theme.colorScheme.onSecondaryContainer),
            label: Text('积分 ${a.credits.toStringAsFixed(2)}'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(AccountView a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除账号 ${a.nickname}'),
        content: const Text(
            '将从账号池移除并记录到删除表，重启后不会被重新发现。\n如需恢复，可在"已删除"提示中选择恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.app.deleteAccount(a.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('已删除 ${a.nickname}'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => widget.app.restoreAccount(a.id),
          ),
        ));
    }
  }

  // ---------- 今日统计 ----------

  Widget _todayStats(BuildContext context) {
    final today = app.todayUsage;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: StatCard(label: '今日请求', value: '${today.requests}')),
        const SizedBox(width: 8),
        Expanded(child: StatCard(label: '今日 Token', value: _formatTokens(today.tokens))),
        const SizedBox(width: 8),
        Expanded(child: StatCard(label: '今日积分消耗', value: today.credits.toStringAsFixed(2))),
      ],
    );
  }

  String _formatTokens(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  // ---------- 本地端点 ----------

  Widget _endpointCard(BuildContext context, RelayConfig config) {
    final anyKeySwitch = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('任意 Key'),
        Switch(
          value: config.allowAnyApiKey,
          onChanged: (v) => _apply(() async => config.allowAnyApiKey = v),
        ),
      ],
    );
    return SectionCard(
      title: '本地端点',
      children: [
        CopyField(label: '端点', value: config.baseUrl),
        const SizedBox(height: 10),
        CopyField(
          label: '密钥',
          value: config.apiKey,
          suffix: [
            IconButton(
              tooltip: '重新生成密钥',
              icon: const Icon(Icons.autorenew),
              onPressed: () => _apply(() => app.regenerateApiKey()),
            ),
            anyKeySwitch,
          ],
        ),
      ],
    );
  }

}
