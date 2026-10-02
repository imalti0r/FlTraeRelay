// account_snapshot.dart - 账号私有存储：把发现的账号完整凭据快照到
// exe 同目录 accounts/<id>.json，实现 Trae 客户端切号后多账号共存。
//
// 快照内容：AuthData 全字段（含 refreshToken，切换后可静默续期）+
// machineId/deviceId（保设备指纹稳定）。加载时合并：快照 ∪ 当前客户端登录态，
// 当前登录态优先（信息最新鲜）。

import 'dart:convert';
import 'dart:io';

import 'auth.dart';

class AccountSnapshotStore {
  AccountSnapshotStore(this.baseDir);

  /// 快照目录（exe 同目录/accounts）。
  final String baseDir;

  String _dir() {
    final d = Directory('$baseDir${Platform.pathSeparator}accounts');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  String _fileFor(String userId) => '${_dir()}${Platform.pathSeparator}$userId.json';

  /// 保存/更新账号快照（完整凭据 + 设备指纹）。
  void save({
    required String userId,
    required AuthData auth,
    required String machineId,
    required String deviceId,
    required String editionId,
  }) {
    if (userId.isEmpty) return;
    final data = {
      'userId': userId,
      'editionId': editionId,
      'savedAt': DateTime.now().toIso8601String(),
      'machineId': machineId,
      'deviceId': deviceId,
      'auth': {
        'accessToken': auth.accessToken,
        'refreshToken': auth.refreshToken,
        'userId': auth.userId,
        'expiredRaw': auth.expiredRaw,
        'expiredTs': auth.expiredTs,
        'host': auth.host,
        'clientId': auth.clientId,
        'psd': auth.psd,
      },
    };
    File(_fileFor(userId)).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
  }

  /// 读取全部快照 → (userId, auth, machineId, deviceId, editionId)。
  List<SnapshottedAccount> loadAll() {
    final dir = Directory(_dir());
    if (!dir.existsSync()) return const [];
    final out = <SnapshottedAccount>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      try {
        final j = jsonDecode(f.readAsStringSync());
        if (j is! Map<String, dynamic>) continue;
        final authJson = j['auth'];
        if (authJson is! Map) continue;
        final auth = AuthData()
          ..accessToken = (authJson['accessToken'] ?? '').toString()
          ..refreshToken = (authJson['refreshToken'] ?? '').toString()
          ..userId = (authJson['userId'] ?? j['userId'] ?? '').toString()
          ..expiredRaw = (authJson['expiredRaw'] ?? '').toString()
          ..expiredTs = (authJson['expiredTs'] as num?)?.toInt() ?? 0
          ..host = (authJson['host'] ?? '').toString()
          ..clientId = (authJson['clientId'] ?? '').toString();
        if (authJson['psd'] is Map) {
          auth.psd.addAll(
              (authJson['psd'] as Map).map((k, v) => MapEntry(k.toString(), v.toString())));
        }
        if (auth.userId.isEmpty || auth.accessToken.isEmpty) continue;
        out.add(SnapshottedAccount(
          userId: auth.userId,
          auth: auth,
          machineId: (j['machineId'] ?? '').toString(),
          deviceId: (j['deviceId'] ?? '').toString(),
          editionId: (j['editionId'] ?? 'solo').toString(),
        ));
      } catch (_) {
        // 单个快照损坏不影响其余
      }
    }
    return out;
  }

  /// 删除某账号快照（账号管理"删除"时调用，配合删除表）。
  void delete(String userId) {
    final f = File(_fileFor(userId));
    if (f.existsSync()) f.deleteSync();
  }
}

class SnapshottedAccount {
  SnapshottedAccount({
    required this.userId,
    required this.auth,
    required this.machineId,
    required this.deviceId,
    required this.editionId,
  });
  final String userId;
  final AuthData auth;
  final String machineId;
  final String deviceId;
  final String editionId;
}
