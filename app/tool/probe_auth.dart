// probe_auth.dart - 枚举 storage.json 全部 auth 键并解密，验证多账号可行性
import 'dart:convert';
import 'dart:io';

import 'package:fltrae_relay/core/storage.dart';

void main() {
  final base = Platform.environment['APPDATA'] ?? '';
  final f = File('$base' + Platform.pathSeparator + 'TRAE SOLO CN' + Platform.pathSeparator + 'User' + Platform.pathSeparator + 'globalStorage' + Platform.pathSeparator + 'storage.json');
  final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final authKeys = j.keys.where((k) => k.startsWith('iCubeAuthInfo://')).toList();
  print('全部 auth 键:');
  for (final k in authKeys) {
    final val = j[k];
    print('  $k (${val is String ? val.length : '?'} chars)');
  }
  // 逐个解密
  for (final k in authKeys) {
    final val = j[k];
    if (val is! String) continue;
    final plain = decryptStorageValue(val);
    if (plain == null) {
      print('  [解密失败] $k');
      continue;
    }
    final a = jsonDecode(plain) as Map<String, dynamic>;
    final userId = ['userId', 'UserID', 'userID', 'user_id', 'uid'].map((x) => a[x]).firstWhere((v) => v != null, orElse: () => null);
    final exp = ['expiredAt', 'TokenExpireAt', 'tokenExpireAt', 'expireAt'].map((x) => a[x]).firstWhere((v) => v != null, orElse: () => null);
    print('  [OK] userId=$userId expired=$exp');
  }
}
