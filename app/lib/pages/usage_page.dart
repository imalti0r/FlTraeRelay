// usage_page.dart - 使用记录：按日期浏览进程内使用记录，展示汇总与明细。

import 'package:flutter/material.dart';

import '../services/backend.dart';
import '../widgets.dart';

class UsagePage extends StatefulWidget {
  const UsagePage({super.key, required this.app});

  final AppState app;

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  DateTime _day = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final records = widget.app.usageForDay(_day);
    var tokens = 0;
    var credits = 0.0;
    for (final r in records) {
      tokens += r.tokens;
      if (r.creditsKnown) credits += r.creditsDelta;
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '前一天',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => setState(() => _day = _day.subtract(const Duration(days: 1))),
            ),
            TextButton(
              onPressed: () => setState(() => _day = DateTime.now()),
              child: Text(_dateLabel(_day)),
            ),
            IconButton(
              tooltip: '后一天',
              icon: const Icon(Icons.chevron_right),
              onPressed: _isToday(_day)
                  ? null
                  : () => setState(() => _day = _day.add(const Duration(days: 1))),
            ),
            const Spacer(),
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                widget.app.refreshOnce();
                setState(() {});
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: StatCard(label: '请求数', value: '${records.length}')),
            const SizedBox(width: 8),
            Expanded(child: StatCard(label: 'Token', value: '$tokens')),
            const SizedBox(width: 8),
            Expanded(child: StatCard(label: '积分消耗', value: credits.toStringAsFixed(2))),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: records.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      '当天暂无使用记录',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : Column(
                  children: [
                    _headerTile(),
                    for (final r in records) _recordTile(r),
                  ],
                ),
        ),
      ],
    );
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  String _dateLabel(DateTime d) {
    if (_isToday(d)) return '今天（${d.year}-${_two(d.month)}-${_two(d.day)}）';
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  /// 列表表头：与 _recordTile 行内各列对齐（同 padding 与列宽）。
  Widget _headerTile() {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.bold,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 26), // 状态图标 + 间距占位
              SizedBox(width: 62, child: Text('时间', style: style)),
              const SizedBox(width: 14),
              Expanded(child: Text('模型', style: style)),
              const SizedBox(width: 14),
              Expanded(child: Text('账号', style: style)),
              const SizedBox(width: 14),
              Text('Token', style: style),
              const SizedBox(width: 14),
              SizedBox(width: 92, child: Text('积分', style: style, textAlign: TextAlign.right)),
              SizedBox(width: 64, child: Text('耗时', style: style, textAlign: TextAlign.right)),
            ],
          ),
          Divider(
            height: 1,
            indent: 26,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }

  Widget _recordTile(UsageRow r) {
    final theme = Theme.of(context);
    final statusColor = r.ok ? theme.colorScheme.primary : theme.colorScheme.error;
    return InkWell(
      onTap: () => _showDetail(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Column(
          children: [
            Row(
              children: [
                Icon(r.ok ? Icons.check_circle_outline : Icons.error_outline, size: 16, color: statusColor),
                const SizedBox(width: 10),
                SizedBox(
                  width: 62,
                  child: Text(_hhmmss(r.ts), style: theme.textTheme.bodyMedium),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Tooltip(
                    message: r.model,
                    child: Text(
                      r.model,
                      style: theme.textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Tooltip(
                    message: r.account,
                    child: Text(
                      r.account,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  '${r.input} / ${r.output}',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 92,
                  child: Text(
                    r.creditsKnown ? '-${r.creditsDelta.toStringAsFixed(4)}' : '--',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Text(
                    '${r.ms}ms',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            Divider(
              height: 1,
              indent: 26,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }

  String _hhmmss(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  /// 点开一条记录：展示具体发送的消息（token）与模型回答内容。
  Future<void> _showDetail(UsageRow r) async {
    final theme = Theme.of(context);
    final detail = widget.app.readDetail(r);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${_hhmmss(r.ts)} · ${r.model}'),
        content: SizedBox(
          width: 720,
          child: detail == null
              ? Text(
                  '该记录没有保存详情（详情功能在本次更新后才有，或详情文件已被清理）。',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                )
              : DefaultTextStyle(
                  style: theme.textTheme.bodySmall!,
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      _detailSection(
                        context,
                        '发送的消息（${((detail['messages'] as List?) ?? []).length} 条）',
                        _messagesWidgets(detail),
                      ),
                      if ((detail['reasoning'] as String?)?.isNotEmpty == true)
                        _detailSection(context, '思考过程（${(detail['reasoning'] as String).length} 字符）', [
                          SelectableText(detail['reasoning'] as String),
                        ]),
                      if ((detail['text'] as String?)?.isNotEmpty == true)
                        _detailSection(context, '回答内容（${(detail['text'] as String).length} 字符）', [
                          SelectableText(detail['text'] as String),
                        ]),
                      if ((detail['toolCalls'] as List?)?.isNotEmpty == true)
                        _detailSection(context, '工具调用', [
                          for (final t in detail['toolCalls'] as List)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: SelectableText(
                                t is Map
                                    ? '${t['name']}(${t['arguments']})'
                                    : t.toString(),
                              ),
                            ),
                        ]),
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  /// messages 数组 → 每条消息一张卡（角色名 + 内容/工具调用）。
  List<Widget> _messagesWidgets(Map<String, dynamic> detail) {
    final msgs = (detail['messages'] as List?) ?? const [];
    if (msgs.isEmpty) return [const Text('（无消息记录）')];
    return [
      for (final m in msgs)
        if (m is Map)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (m['role'] ?? '').toString().toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 4),
                SelectableText((m['content'] ?? '').toString()),
                if (m['tool_calls'] is List)
                  for (final tc in m['tool_calls'] as List)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: SelectableText(
                        tc is Map
                            ? '→ ${tc['name']}(${tc['arguments']})'
                            : tc.toString(),
                        style: TextStyle(color: Theme.of(context).colorScheme.tertiary),
                      ),
                    ),
              ],
            ),
          ),
    ];
  }

  Widget _detailSection(BuildContext context, String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }
}
