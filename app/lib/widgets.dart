// widgets.dart - 页面共用的小组件：玻璃区块卡片、玻璃统计卡、可复制字段行。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 带标题的玻璃区块卡片（对应原 GUI 的"当前账号/本地端点/模型设置"卡）。
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: const LiquidRoundedSuperellipse(borderRadius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              const Spacer(),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

/// 玻璃统计卡：标签 + 大数字。
class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(value, style: theme.textTheme.headlineSmall),
        ],
      ),
    );
  }
}

/// 标签 + 只读值 + 复制按钮的一行；suffix 追加在复制按钮之后。
class CopyField extends StatefulWidget {
  const CopyField({super.key, required this.label, required this.value, this.suffix, this.obscure = false});

  final String label;
  final String value;
  final List<Widget>? suffix;
  final bool obscure;

  @override
  State<CopyField> createState() => _CopyFieldState();
}

class _CopyFieldState extends State<CopyField> {
  late final TextEditingController _controller = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(CopyField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 72, child: Text(widget.label, style: Theme.of(context).textTheme.bodyMedium)),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            readOnly: true,
            obscureText: widget.obscure,
            controller: _controller,
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: const InputDecoration(),
          ),
        ),
        const SizedBox(width: 8),
        GlassIconButton(
          icon: const Icon(Icons.copy_outlined, size: 18),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: widget.value));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(content: Text('已复制${widget.label}')));
            }
          },
          size: 36,
          semanticLabel: '复制',
        ),
        if (widget.suffix != null) ...[
          const SizedBox(width: 8),
          ...widget.suffix!,
        ],
      ],
    );
  }
}

/// 配置写入后的统一提示。
void showConfigSaved(BuildContext context, {required bool backendRunning}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(backendRunning ? '已写入 config.json，重启后端后生效' : '已写入 config.json'),
      action: backendRunning ? null : SnackBarAction(label: '知道了', onPressed: () {}),
    ));
}
