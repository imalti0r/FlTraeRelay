// main.dart - FlTraeRelay 入口：Material 3 外壳 + NavigationRail 三页导航。
// 以 sidecar 方式驱动官方 TraeRelay.exe --serve，作为其 MD3 风格前端。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pages/models_page.dart';
import 'pages/overview.dart';
import 'pages/settings_page.dart';
import 'pages/usage_page.dart';
import 'services/backend.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  runApp(FlTraeRelayApp(app: app));
}

class FlTraeRelayApp extends StatelessWidget {
  const FlTraeRelayApp({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlTraeRelay',
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.system,
      home: AppShell(app: app),
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
        return Scaffold(
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
              child: Row(
            children: [
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                extended: MediaQuery.widthOf(context) >= 1000,
                minExtendedWidth: 160,
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    children: [
                      Icon(
                        Icons.bolt,
                        size: 32,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 4),
                      const Text('FlTraeRelay'),
                    ],
                  ),
                ),
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.dashboard_outlined),
                    selectedIcon: Icon(Icons.dashboard),
                    label: Text('运行总览'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.memory_outlined),
                    selectedIcon: Icon(Icons.memory),
                    label: Text('模型'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.receipt_long_outlined),
                    selectedIcon: Icon(Icons.receipt_long),
                    label: Text('使用记录'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: Text('偏好设置'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: switch (_index) {
                  0 => OverviewPage(app: app),
                  1 => ModelsPage(app: app),
                  2 => UsagePage(app: app),
                  _ => SettingsPage(app: app),
                },
              ),
            ],
              ),
            ),
          ),
        );
      },
    );
  }
}
