// config_store.dart - config.json 的加载与原子保存（tmp + rename，与 C++ Config::save 一致）。

import 'dart:convert';
import 'dart:io';

import '../models.dart';

class ConfigStore {
  ConfigStore(this.path);

  final String path;

  static const fileName = 'config.json';

  /// 与 C++ 一致：config.json 位于后端 exe 同目录。
  static String configPathFor(String exePath) {
    final dir = File(exePath).parent.path;
    return '$dir${Platform.pathSeparator}$fileName';
  }

  Future<RelayConfig> load() async {
    final f = File(path);
    if (!f.existsSync()) {
      return RelayConfig(<String, dynamic>{});
    }
    final decoded = jsonDecode(await f.readAsString());
    return RelayConfig(decoded is Map<String, dynamic> ? decoded : <String, dynamic>{});
  }

  Future<void> save(RelayConfig config) async {
    final f = File(path);
    const encoder = JsonEncoder.withIndent('  ');
    final tmp = '${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp';
    final t = File(tmp);
    await t.writeAsString(encoder.convert(config.raw));
    await t.rename(f.path);
  }
}
