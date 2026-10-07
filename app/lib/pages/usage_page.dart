// usage_page.dart - 使用记录：按日期浏览进程内使用记录，展示汇总与明细。

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

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
  int _page = 0;
  static const _pageSize = 14;

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
    // 分页展示：统计卡吃全量数据，列表只渲染当前页。
    final totalPages = records.isEmpty ? 1 : (records.length + _pageSize - 1) ~/ _pageSize;
    if (_page >= totalPages) _page = totalPages - 1;
    final pageStart = _page * _pageSize;
    final pageEnd = pageStart + _pageSize > records.length ? records.length : pageStart + _pageSize;
    final pageRecords = records.sublist(pageStart, pageEnd);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 60, 20, 100),
      children: [
        Row(
          children: [
            GlassIconButton(
              icon: const Icon(Icons.chevron_left, size: 22),
              onPressed: () => setState(() {
                _day = _day.subtract(const Duration(days: 1));
                _page = 0;
              }),
              size: 40,
              semanticLabel: '前一天',
            ),
            TextButton(
              onPressed: () => setState(() {
                _day = DateTime.now();
                _page = 0;
              }),
              child: Text(_dateLabel(_day)),
            ),
            GlassIconButton(
              icon: const Icon(Icons.chevron_right, size: 22),
              onPressed: _isToday(_day)
                  ? null
                  : () => setState(() {
                      _day = _day.add(const Duration(days: 1));
                      _page = 0;
                    }),
              size: 40,
              semanticLabel: '后一天',
            ),
            const Spacer(),
            GlassIconButton(
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () {
                widget.app.refreshOnce();
                setState(() {
                  _page = 0;
                });
              },
              size: 40,
              semanticLabel: '刷新',
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 三张统计卡同一行。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: StatCard(label: '请求数', value: '${records.length}')),
            const SizedBox(width: 8),
            Expanded(child: StatCard(label: 'Token', value: '$tokens')),
            const SizedBox(width: 8),
            Expanded(child: StatCard(label: '积分消耗', value: credits.toStringAsFixed(2))),
          ],
        ),        const SizedBox(height: 8),
        GlassCard(
          padding: EdgeInsets.zero,
          shape: const LiquidRoundedSuperellipse(borderRadius: 20),
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
              // 窄窗放不下七列表：表头与明细包进同一横向滚动容器保持对齐。
              // 行内有 Expanded，必须给它有界宽度——窄窗用 660 起步可横滚，
              // 宽窗拉伸到可用宽度。
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final tableWidth = constraints.maxWidth.isFinite
                        ? constraints.maxWidth < 660
                              ? 660.0
                              : constraints.maxWidth
                        : 660.0;
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: tableWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _headerTile(),
                            for (final r in pageRecords) _recordTile(r),
                            _paginationBar(totalPages, records.length),
                          ],
                        ),
                      ),
                    );
                  },
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
                    r.creditsKnown ? '-${r.creditsDelta.toStringAsFixed(2)}' : '--',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Text(
                    _secondsLabel(r.ms),
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

  /// 分页栏：上一页/下一页 + 页码与总数。
  Widget _paginationBar(int totalPages, int totalRecords) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GlassIconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            onPressed: _page > 0 ? () => setState(() => _page -= 1) : null,
            size: 34,
            semanticLabel: '上一页',
          ),
          const SizedBox(width: 12),
          Text(
            '第 ${_page + 1} / $totalPages 页 · 共 $totalRecords 条',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          GlassIconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: _page < totalPages - 1 ? () => setState(() => _page += 1) : null,
            size: 34,
            semanticLabel: '下一页',
          ),
        ],
      ),
    );
  }

  /// 点开一条记录：液态玻璃弹窗展示积分/耗时与具体发送的消息、回答内容。
  Future<void> _showDetail(UsageRow r) async {
    final theme = Theme.of(context);
    final detail = widget.app.readDetail(r);
    if (!mounted) return;
    await GlassDialog.show(
      context: context,
      barrierDismissible: true,
      maxWidth: 560,
      title: '${_hhmmss(r.ts)} · ${r.model}',
      message: '积分 ${r.creditsKnown ? '-${r.creditsDelta.toStringAsFixed(2)}' : '--'}'
          ' · 耗时 ${_secondsLabel(r.ms)}',
      content: ConstrainedBox(
        // 长内容在玻璃弹窗内滚动，最高占窗口高度 62%。
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.62),
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
        GlassDialogAction(
          label: '关闭',
          isPrimary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  /// 耗时统一以秒展示，保留两位小数。
  String _secondsLabel(int ms) => '${(ms / 1000).toStringAsFixed(2)}s';

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
