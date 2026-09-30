// usage_store.dart - 解析 usage/usage-YYYYMMDD.jsonl（与后端 exe 同目录），
// 提供今日汇总与分页明细，对应原 GUI 的"使用记录"页。

import 'dart:convert';
import 'dart:io';

import '../models.dart';

class UsageStore {
  UsageStore(this.exePath);

  /// 后端 exe 路径，usage 目录位于其同目录。
  final String exePath;

  String get usageDir {
    final dir = File(exePath).parent.path;
    return '$dir${Platform.pathSeparator}usage';
  }

  String _fileFor(DateTime day) {
    final y = day.year.toString().padLeft(4, '0');
    final m = day.month.toString().padLeft(2, '0');
    final d = day.day.toString().padLeft(2, '0');
    return '$usageDir${Platform.pathSeparator}usage-$y$m$d.jsonl';
  }

  /// 读取指定日期（默认今天）的记录，时间倒序。
  Future<List<UsageRecord>> recordsFor(DateTime day) async {
    final f = File(_fileFor(day));
    if (!f.existsSync()) return const [];
    final lines = await f.readAsLines();
    final out = <UsageRecord>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) {
          out.add(UsageRecord.fromJson(decoded.map((k, v) => MapEntry(k.toString(), v))));
        }
      } catch (_) {
        // 单行损坏不影响其余记录
      }
    }
    out.sort((a, b) => b.ts.compareTo(a.ts));
    return out;
  }

  /// 汇总指定日期（本地时区口径，与 C++ usageCountToday 一致）。
  Future<TodayUsage> usageFor(DateTime day) async {
    final records = await recordsFor(day);
    final u = TodayUsage(requests: 0, tokens: 0, credits: 0);
    for (final r in records) {
      u.requests += 1;
      u.tokens += r.tokens;
      u.credits += r.creditsDelta;
    }
    return u;
  }
}
