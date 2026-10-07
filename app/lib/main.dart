// main.dart - FlTraeRelay 入口：液态玻璃外壳 + 悬浮玻璃底栏四页导航。
// 以 sidecar 方式驱动官方 TraeRelay.exe --serve，作为其液态玻璃风格前端。
// 原生标题栏已禁用，顶部玻璃标题栏由这里自绘并经 MethodChannel 控制窗口。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'pages/models_page.dart';
import 'pages/overview.dart';
import 'pages/settings_page.dart';
import 'pages/usage_page.dart';
import 'services/backend.dart';
import 'theme.dart';

/// 窗口控制通道（原生端实现：最小化/最大化切换/关闭）。
const MethodChannel _windowChannel = MethodChannel('fltrae_relay/window');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 预热玻璃渲染管线（shader 编译 + 字形预取）。
  await LiquidGlassWidgets.initialize();
  final app = AppState();
  runApp(LiquidGlassWidgets.wrap(
    // MaterialApp 场景必须桥接主题明暗，玻璃组件才能跟随亮/暗模式。
    brightnessResolver: Theme.maybeBrightnessOf,
    child: FlTraeRelayApp(app: app),
  ));
}

class FlTraeRelayApp extends StatelessWidget {
  const FlTraeRelayApp({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        // 主题模式持久化在 config.json 的 ui.themeMode，默认跟随系统。
        final mode = switch (app.themeModeName) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
        return MaterialApp(
          title: 'FlTraeRelay',
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: mode,
          home: AppShell(app: app),
        );
      },
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.app});

  final AppState app;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  @override
  void initState() {
    super.initState();
    widget.app.init();
    // 监听"关闭最小化到托盘"开关：设置变更或后端重启后推送到原生层
    widget.app.addListener(_pushTraySetting);
  }

  Future<void> _pushTraySetting() async {
    await widget.app.pushTraySetting();
  }

  @override
  void dispose() {
    widget.app.removeListener(_pushTraySetting);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        // theme 必须在 builder 内取：主题切换经 notifyListeners 走这里，
        // 在外层取会拿到旧主题。
        final theme = Theme.of(context);
        Widget page = switch (_index) {
          0 => OverviewPage(app: app),
          1 => ModelsPage(app: app),
          2 => UsagePage(app: app),
          _ => SettingsPage(app: app),
        };
        page = KeyedSubtree(key: ValueKey(_index), child: page);
        final windowWidth = MediaQuery.sizeOf(context).width;
        return GlassScaffold(
          // 渐变光斑背景：玻璃折射/模糊需要背后有色彩变化才可见。
          background: GlassBackdrop(brightness: theme.brightness),
          // 自绘玻璃标题栏：左侧标题，右侧窗口控制按钮；拖动区由原生
          // WM_NCHITTEST 返回 HTCAPTION 处理，按钮区（右上 110 逻辑像素）归这里。
          appBar: SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(Icons.bolt, size: 22, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('FlTraeRelay', style: theme.textTheme.titleMedium),
                const Spacer(),
                GlassIconButton(
                  icon: const Icon(Icons.remove, size: 18),
                  onPressed: () => _windowChannel.invokeMethod('minimize'),
                  size: 36,
                  semanticLabel: '最小化',
                ),
                const SizedBox(width: 8),
                GlassIconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _windowChannel.invokeMethod('close'),
                  size: 36,
                  semanticLabel: '关闭',
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
          // 限宽居中：胶囊不随窗口拉满，窄窗下也不超窗
          bottomBarHeight: 76,
          bottomBar: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.min(300.0, windowWidth - 16),
              ),
              child: GlassTabBar.bottom(
                selectedIndex: _index,
                onTabSelected: (i) => setState(() => _index = i),
                // 紧凑纯图标样式：无文字，缩小栏高与外边距
                barHeight: 48,
                verticalPadding: 14,
                tabs: const [
                  GlassTab(
                    icon: Icon(Icons.dashboard_outlined),
                    activeIcon: Icon(Icons.dashboard),
                    semanticLabel: '运行总览',
                  ),
                  GlassTab(
                    icon: Icon(Icons.memory_outlined),
                    activeIcon: Icon(Icons.memory),
                    semanticLabel: '模型',
                  ),
                  GlassTab(
                    icon: Icon(Icons.receipt_long_outlined),
                    activeIcon: Icon(Icons.receipt_long),
                    semanticLabel: '使用记录',
                  ),
                  GlassTab(
                    icon: Icon(Icons.settings_outlined),
                    activeIcon: Icon(Icons.settings),
                    semanticLabel: '偏好设置',
                  ),
                ],
              ),
            ),
          ),
          body: CallbackShortcuts(
            bindings: {
              // Ctrl+1..4 切换页面（桌面键盘导航）
              const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
                  setState(() => _index = 0),
              const SingleActivator(LogicalKeyboardKey.digit2, control: true): () =>
                  setState(() => _index = 1),
              const SingleActivator(LogicalKeyboardKey.digit3, control: true): () =>
                  setState(() => _index = 2),
              const SingleActivator(LogicalKeyboardKey.digit4, control: true): () =>
                  setState(() => _index = 3),
            },
            child: Focus(
              autofocus: true,
              // GlassScaffold 基于 CupertinoPageScaffold，Material 控件需要透明
              // Material 上下文才能正常渲染。
              child: Material(
                type: MaterialType.transparency,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: page,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
