// theme.dart - 液态玻璃主题：以 Trae 品牌青绿为种子色，亮/暗两套。
// 卡片与导航表面由 liquid_glass_widgets 的玻璃组件承担，这里保留 Material
// 控件（按钮/输入框/弹窗）的主题并整体调成玻璃风格的大圆角外观。

import 'package:flutter/material.dart';

const seedColor = Color(0xFF0B9E83);

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: seedColor);
  return _base(scheme, Brightness.light);
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.dark);
  return _base(scheme, Brightness.dark);
}

ThemeData _base(ColorScheme scheme, Brightness brightness) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    // 背景交给 GlassScaffold 的渐变光斑，页面自身保持透明。
    scaffoldBackgroundColor: Colors.transparent,
    cardTheme: CardThemeData(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 8),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      isDense: true,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}

/// 液态玻璃渐变背景：大尺寸柔和光斑让玻璃容器的折射/模糊可见。
/// 作为 GlassScaffold.background 使用，跟随亮暗模式切换配色。
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.brightness});

  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final dark = brightness == Brightness.dark;
    final base = dark
        ? const [Color(0xFF0B1412), Color(0xFF0C1420)]
        : const [Color(0xFFF4FBF9), Color(0xFFEAF2F6)];
    final blobs = dark
        ? const [_ColorBlob(Color(0xFF0B9E83), 0.28, Alignment(-0.7, -0.8)),
                 _ColorBlob(Color(0xFF4B5BD6), 0.20, Alignment(0.85, -0.5)),
                 _ColorBlob(Color(0xFF16B7A6), 0.12, Alignment(0.4, 0.9))]
        : const [_ColorBlob(Color(0xFF0B9E83), 0.14, Alignment(-0.7, -0.8)),
                 _ColorBlob(Color(0xFF3D7BFF), 0.10, Alignment(0.85, -0.5)),
                 _ColorBlob(Color(0xFFFF7AB8), 0.08, Alignment(0.4, 0.9))];

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: base,
              ),
            ),
          ),
          for (final blob in blobs)
            Align(
              alignment: blob.alignment,
              child: FractionallySizedBox(
                widthFactor: 0.75,
                heightFactor: 0.6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        blob.color.withValues(alpha: blob.alpha),
                        blob.color.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ColorBlob {
  const _ColorBlob(this.color, this.alpha, this.alignment);

  final Color color;
  final double alpha;
  final Alignment alignment;
}
