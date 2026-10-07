// models_page.dart - 模型页：列表展示全部可用模型，并在每个模型行内直接
// 设置思考强度、Max 模式与启用状态（写入 config.json 的 models.<name> 覆盖项）。

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../models.dart';
import '../services/backend.dart';
import '../widgets.dart';

String _effortLabel(String v) {
  switch (v) {
    case 'light':
    case 'low':
      return '轻';
    case 'high':
      return '高';
    case 'extra_high':
      return '极高';
    default:
      return v;
  }
}

String _formatContext(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(0)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}K';
  return '$n';
}

String? _activityLabel(String type) {
  switch (type) {
    case 'limited':
      return '限时折扣';
    case 'subsidy':
      return '专属补贴';
    case 'off_peak':
      return '闲时折扣';
    default:
      return type.isEmpty ? null : '活动价';
  }
}

class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key, required this.app});

  final AppState app;

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  String _query = '';

  AppState get app => widget.app;
  RelayConfig? get cfg => app.config;

  Future<void> _apply(String model, Map<String, dynamic> fields) async {
    final config = cfg;
    if (config == null) return;
    config.upsertModelOverride(model, fields);
    final ok = await app.saveConfig();
    if (!mounted) return;
    if (ok) {
      showConfigSaved(context, backendRunning: app.backendRunning);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final models = app.modelCatalogViews;
    final filtered = _query.isEmpty
        ? models
        : models
            .where((m) =>
                m.id.toLowerCase().contains(_query) ||
                m.displayName.toLowerCase().contains(_query))
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 60, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('可用模型（${models.length}）',
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis),
                  ),
                  GlassIconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: app.backendRunning ? () => app.refreshModels() : null,
                    size: 40,
                    semanticLabel: '刷新模型目录',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 44,
                child: GlassSearchBar(
                  placeholder: '搜索模型',
                  onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Text(
            app.backendRunning
                ? '设置写入 config.json 的 models 覆盖项，重启后端后生效'
                : '后端未运行，启动后自动拉取模型目录',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    models.isEmpty
                        ? (app.backendRunning ? '模型列表为空：等待目录拉取或账号不可用' : '后端未运行')
                        : '没有匹配 "$_query" 的模型',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                  children: [
                    for (final m in filtered) _modelCard(context, m),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _modelCard(BuildContext context, ModelCatalogView m) {
    final theme = Theme.of(context);
    final config = cfg;
    final override = config?.modelOverride(m.id);

    // 启用状态：覆盖项缺省视为启用
    final enabled = override?['enabled'] is bool ? override!['enabled'] as bool : true;
    // 思考强度：覆盖值优先；'' 表示跟随模型目录 default_level
    final overrideEffort = config?.modelReasoningEffort(m.id);
    final effectiveEffort = overrideEffort ?? '';
    // Max：覆盖值优先，回落 defaults
    final overrideMax = config?.modelIsMaxMode(m.id);
    final maxMode = overrideMax != null ? overrideMax != 0 : config!.isMaxMode != 0;

    // 分段控件按索引取值：'' 为"默认"档，其余依次对应模型支持的档位
    final effortValues = <String>['', ...m.effortOptions];
    final effortSelected = effortValues.indexOf(effectiveEffort);

    return GlassCard(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      shape: const LiquidRoundedSuperellipse(borderRadius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(m.label, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
              ),
              if (m.maxMode)
                _Tag(label: 'Max', color: theme.colorScheme.primaryContainer, textColor: theme.colorScheme.onPrimaryContainer),
              if (m.vision)
                _Tag(label: '视觉', color: theme.colorScheme.secondaryContainer, textColor: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 8),
              GlassSwitch(
                value: enabled,
                activeColor: theme.colorScheme.primary,
                onChanged: (v) => _apply(m.id, {'enabled': v}),
              ),
            ],
          ),
            const SizedBox(height: 2),
            Text(
              _subtitle(m),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 76,
                  child: Text('思考强度', style: theme.textTheme.bodyMedium),
                ),
                Expanded(
                  child: m.supportThinking && effortValues.length > 1
                      ? GlassSegmentedControl(
                          segments: [
                            for (final v in effortValues)
                              GlassSegment(label: v.isEmpty ? '默认' : _effortLabel(v)),
                          ],
                          selectedIndex: effortSelected < 0 ? 0 : effortSelected,
                          onSegmentSelected: (i) => _apply(m.id, {
                            'reasoningEffort': effortValues[i].isEmpty ? null : effortValues[i],
                          }),
                        )
                      : Text(
                          '不支持思考档位',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Max 独立一行右对齐，避免窄窗下与分段控件互相挤压。
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Text('Max'),
                const SizedBox(width: 8),
                // GlassSwitch 无禁用态：不支持的模型降透明度并吞掉手势。
                Opacity(
                  opacity: m.maxMode ? 1 : 0.4,
                  child: IgnorePointer(
                    ignoring: !m.maxMode,
                    child: GlassSwitch(
                      value: maxMode,
                      activeColor: theme.colorScheme.primary,
                      onChanged: m.maxMode
                          ? (v) => _apply(m.id, {'isMaxMode': v ? 1 : 0})
                          : (_) {},
                    ),
                  ),
                ),
              ],
            ),
          ],
      ),
    );
  }

  String _subtitle(ModelCatalogView m) {
    final parts = <String>[m.id];
    if (m.cwDefault > 0) {
      final maxCw = m.cwMax.isEmpty ? 0 : m.cwMax.reduce((a, b) => a > b ? a : b);
      parts.add(maxCw > m.cwDefault ? '上下文 ${_formatContext(m.cwDefault)}～${_formatContext(maxCw)}' : '上下文 ${_formatContext(m.cwDefault)}');
    }
    final rate = m.rateLabel;
    if (rate != null) {
      var ratePart = '倍率 x$rate';
      final act = _activityLabel(m.activityType);
      if (m.rateActivity > 0 && act != null) ratePart += '（$act）';
      parts.add(ratePart);
    }
    if (m.supportThinking && m.effortDefault.isNotEmpty) {
      parts.add('默认档位 ${_effortLabel(m.effortDefault)}');
    }
    return parts.join(' · ');
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color, required this.textColor});

  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(fontSize: 11, color: textColor)),
    );
  }
}
