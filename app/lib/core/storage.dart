// storage.dart - Trae 凭据存储：发行版发现、storage.json 读取、tc 解密
// （AES-128-CBC，CNG 格式）、设备 ID、安装目录与 IDE 版本探测。
// 对应 C++ src/accounts/Storage.cpp，四个硬编码盐来自 Trae CN 前端 JS 逆向。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'auth.dart';
import 'crypto_x.dart';
import 'win_registry.dart';

// 四个 64 字节盐：private 盐 = C^D，普通盐 = A^B（与 C++ 完全一致）
const List<int> _saltA = [
  82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251,
  124, 227, 57, 130, 155, 47, 255, 135, 52, 142, 67, 68, 196, 222, 233, 203,
  84, 123, 148, 50, 166, 194, 35, 61, 238, 76, 149, 11, 66, 250, 195, 78,
  8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109, 139, 209, 37,
];
const List<int> _saltB = [
  31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95,
  96, 81, 127, 169, 25, 181, 74, 13, 45, 229, 122, 159, 147, 201, 156, 239,
  160, 224, 59, 77, 174, 42, 245, 176, 200, 235, 187, 60, 131, 83, 153, 97,
  23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99, 85, 33, 12, 125,
];
const List<int> _saltC = [
  191, 192, 216, 250, 122, 246, 220, 97, 31, 254, 98, 27, 8, 72, 71, 176,
  135, 99, 96, 18, 127, 101, 203, 104, 211, 102, 191, 125, 37, 72, 150, 156,
  51, 229, 121, 35, 17, 153, 141, 177, 110, 131, 150, 128, 172, 255, 254, 6,
  18, 140, 55, 62, 236, 249, 135, 64, 135, 12, 117, 4, 89, 149, 168, 209,
];
const List<int> _saltD = [
  246, 204, 26, 232, 232, 70, 129, 109, 223, 146, 169, 242, 23, 241, 105, 145,
  50, 196, 165, 42, 254, 120, 3, 54, 244, 207, 209, 85, 53, 6, 138, 106,
  175, 148, 31, 204, 186, 186, 165, 182, 87, 142, 49, 10, 39, 110, 26, 154,
  86, 56, 173, 125, 18, 64, 198, 225, 99, 99, 83, 82, 191, 134, 76, 170,
];

final List<int> _saltPublic = [for (var i = 0; i < 64; i++) _saltA[i] ^ _saltB[i]];
final List<int> _saltPrivate = [for (var i = 0; i < 64; i++) _saltC[i] ^ _saltD[i]];

/// tc blob 解密：[6B Header][32B Random][N AES-128-CBC 密文]。
/// 头 `74 63 05 10 00 00`（"tc"）为普通 AES；`12 39 20 20 02 03` 为 PRIVATE。
/// 明文结构：[64B sha512(body)][PKCS7 body]。
String? decryptStorageValue(String base64Value) {
  Uint8List buf;
  try {
    buf = base64Decode(base64Value);
  } catch (_) {
    return null;
  }
  if (buf.length < 38 + 16) return null;
  final header = buf.sublist(0, 6);
  final rnd = buf.sublist(6, 38);
  final enc = buf.sublist(38);

  final isAes = header[0] == 0x74 && header[1] == 0x63 && header[2] == 0x05 &&
      header[3] == 0x10 && header[4] == 0x00 && header[5] == 0x00;
  final isPriv = header[0] == 18 && header[1] == 57 && header[2] == 32 &&
      header[3] == 32 && header[4] == 2 && header[5] == 3;
  if (!isAes && !isPriv) return null;

  for (final usePriv in [isPriv, !isPriv]) {
    final salt = usePriv ? _saltPrivate : _saltPublic;
    final h = sha512Bytes(rnd); // 32 字节 random → sha512
    final f = sha512Bytes([...h, ...salt]);
    final key = Uint8List.fromList(f.sublist(0, 16));
    final iv = Uint8List.fromList(f.sublist(16, 32));
    final dec = aes128CbcDecrypt(key, iv, enc);
    if (dec == null || dec.length <= 64) continue;
    final storedHash = dec.sublist(0, 64);
    final body = dec.sublist(64);
    final calc = sha512Bytes(body);
    if (_bytesEqual(calc, storedHash)) {
      return utf8.decode(body, allowMalformed: true);
    }
  }
  return null;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 发现本机已登录的 Trae 发行版（多账号：五个发行版全部扫描）。
List<TraeEdition> discoverEditions() {
  final base = _appDataDir();
  if (base.isEmpty) return const [];
  const dirs = {
    'Trae CN': 'cn',
    'TRAE SOLO CN': 'solo',
    'Trae Work CN': 'work',
    'Trae': 'sg',
    'TRAE SOLO': 'solo-sg',
  };
  final out = <TraeEdition>[];
  for (final entry in dirs.entries) {
    final userDir = '$base\\${entry.key}\\User';
    final f = File('$userDir\\globalStorage\\storage.json');
    if (f.existsSync()) {
      out.add(TraeEdition(id: entry.value, userDir: userDir, label: entry.key));
    }
  }
  return out;
}

String _appDataDir() {
  final env = Platform.environment['APPDATA'];
  return env ?? '';
}

String _readTextFile(String path, {int maxBytes = 64 * 1024 * 1024}) {
  try {
    final f = File(path);
    if (!f.existsSync()) return '';
    if (f.lengthSync() <= 0 || f.lengthSync() > maxBytes) return '';
    return f.readAsStringSync();
  } catch (_) {
    return '';
  }
}

String _readRawFile(String path, {int maxBytes = 128 * 1024}) {
  try {
    final f = File(path);
    if (!f.existsSync()) return '';
    if (f.lengthSync() <= 0 || f.lengthSync() > maxBytes) return '';
    return f.readAsStringSync();
  } catch (_) {
    return '';
  }
}

/// machineId：storage.json 的 telemetry.machineId，回退发行版根 machineid 文件。
String readMachineId(String userDir) {
  final sp = '$userDir\\globalStorage\\storage.json';
  final text = _readTextFile(sp);
  if (text.isNotEmpty) {
    try {
      final j = jsonDecode(text);
      final v = j['telemetry.machineId'];
      if (v is String && v.length >= 32) return v;
    } catch (_) {}
  }
  final root = userDir.replaceAll(RegExp(r'\\User$'), '');
  final raw = _readRawFile('$root\\machineid');
  return raw.replaceAll(RegExp(r'\s'), '');
}

/// deviceId：machineid 文件优先，回退 telemetry.devDeviceId。
String readDeviceId(String userDir) {
  final root = userDir.replaceAll(RegExp(r'\\User$'), '');
  final raw = _readRawFile('$root\\machineid');
  final local = raw.replaceAll(RegExp(r'\s'), '');
  if (local.isNotEmpty) return local;
  final text = _readTextFile('$userDir\\globalStorage\\storage.json');
  if (text.isNotEmpty) {
    try {
      final j = jsonDecode(text);
      final v = j['telemetry.devDeviceId'];
      if (v is String && v.isNotEmpty) return v;
    } catch (_) {}
  }
  return '';
}

/// AHA/TTNet 设备 ID：发行版根 aha\TinyStorage 里 tc 加密的 device_id_str。
/// 签到 claim 按它校验设备，读不到会被 9074 软拒。
String readAhaDeviceId(String userDir) {
  final root = userDir.replaceAll(RegExp(r'\\User$'), '');
  final text = _readTextFile('$root\\aha\\TinyStorage', maxBytes: 1024 * 1024);
  if (text.isEmpty) return '';
  Map<String, dynamic> j;
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return '';
    j = decoded;
  } catch (_) {
    return '';
  }
  final data = j['tiny_storage_data'];
  if (data is! Map) return '';
  final idv = data['aha.device.device_id'];
  if (idv is! String || idv.isEmpty) return '';
  final plain = decryptStorageValue(idv);
  if (plain == null) return '';
  try {
    final dj = jsonDecode(plain);
    final did = dj['device_id_str'];
    if (did is String && did.isNotEmpty) return did;
  } catch (_) {}
  return '';
}

/// 过期时间解析：纯数字（秒/毫秒）或 ISO 8601。
int parseExpiry(String raw) {
  if (raw.isEmpty) return 0;
  final numV = double.tryParse(raw);
  if (numV != null && numV > 0) {
    var v = numV;
    if (v > 1e12) v /= 1000.0; // 毫秒
    return v.toInt();
  }
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})').firstMatch(raw);
  if (m != null) {
    var utc = DateTime.utc(int.parse(m.group(1)!), int.parse(m.group(2)!),
        int.parse(m.group(3)!), int.parse(m.group(4)!), int.parse(m.group(5)!),
        int.parse(m.group(6)!));
    // 时区后缀
    final zIdx = raw.indexOf('Z');
    if (zIdx < 0) {
      final tz = RegExp(r'([+-])(\d{2}):(\d{2})$').firstMatch(raw);
      if (tz != null) {
        final off = int.parse(tz.group(2)!) * 3600 + int.parse(tz.group(3)!) * 60;
        utc = utc.subtract(Duration(seconds: tz.group(1) == '-' ? -off : off));
      }
    }
    return utc.millisecondsSinceEpoch ~/ 1000;
  }
  return 0;
}

String _firstString(Map<String, dynamic> j, List<String> keys) {
  for (final k in keys) {
    final v = j[k];
    if (v is String && v.isNotEmpty) return v;
  }
  return '';
}

void _fillPsd(AuthData a, Map<String, dynamic> j) {
  void put(String key, List<String> aliases) {
    final v = _firstString(j, aliases);
    if (v.isNotEmpty) a.psd[key] = v;
  }

  put('webId', ['webId', 'web_id', 'WebId']);
  put('bizUserId', ['bizUserId', 'biz_user_id', 'BizUserId']);
  put('userUniqueId', ['userUniqueId', 'user_unique_id', 'UserUniqueId']);
  put('scope', ['scope', 'Scope']);
  put('tenant', ['tenant', 'Tenant']);
  put('region', ['region', 'Region']);
  put('aiRegion', ['aiRegion', 'AIRegion']);
  put('appLanguage', ['appLanguage', 'AppLanguage']);
  put('appVersion', ['appVersion', 'AppVersion']);
  put('userRegion', ['userRegion', 'UserRegion']);
  put('userIdentity', ['userIdentity', 'UserIdentity']);
  for (final key in ['providerSpecificData', 'commonParams', 'common_params']) {
    final nested = j[key];
    if (nested is Map) {
      _fillPsd(a, nested.map((k, v) => MapEntry(k.toString(), v)));
      break;
    }
  }
}

/// 读取并解密 storage.json 的 iCubeAuthInfo 凭据。
(String, AuthData?) readAuth(String userDir) {
  final sp = '$userDir\\globalStorage\\storage.json';
  final text = _readTextFile(sp);
  if (text.isEmpty) {
    return ('无法打开或读取 $sp', null);
  }
  Map<String, dynamic> root;
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return ('storage.json 不是 JSON 对象', null);
    root = decoded;
  } catch (e) {
    return ('storage.json 不是合法 JSON: $e', null);
  }
  final encVal = root['iCubeAuthInfo://icube.cloudide'];
  if (encVal is! String || encVal.isEmpty) {
    return ('storage.json 缺少 iCubeAuthInfo://icube.cloudide', null);
  }
  Map<String, dynamic> auth;
  final trimmed = encVal.trim();
  if (trimmed.startsWith('{')) {
    // 明文 JSON 兜底（部分版本/国际版）
    try {
      auth = jsonDecode(trimmed) as Map<String, dynamic>;
    } catch (e) {
      return ('iCubeAuthInfo 明文 JSON 解析失败: $e', null);
    }
  } else {
    final plain = decryptStorageValue(encVal);
    if (plain == null) return ('tc 解密失败（两种盐均不匹配或格式未知）', null);
    try {
      auth = jsonDecode(plain) as Map<String, dynamic>;
    } catch (e) {
      return ('tc 解密成功但 JSON 解析失败: $e', null);
    }
  }

  final out = AuthData()
    ..raw = auth
    ..accessToken = _firstString(auth, ['token', 'accessToken', 'AccessToken', 'access_token'])
    ..refreshToken = _firstString(auth, ['refreshToken', 'RefreshToken', 'refresh_token'])
    ..userId = _firstString(auth, ['userId', 'UserID', 'userID', 'user_id', 'uid'])
    ..expiredRaw = _firstString(auth, ['expiredAt', 'TokenExpireAt', 'tokenExpireAt', 'expireAt'])
    ..host = _firstString(auth, ['host', 'Host'])
    ..clientId = _firstString(auth, ['clientID', 'ClientID', 'clientId']);
  out.expiredTs = parseExpiry(out.expiredRaw);
  _fillPsd(out, auth);
  if (out.accessToken.isEmpty) {
    return ('解密结果中没有 token 字段', null);
  }
  return ('', out);
}

/// 探测 Trae 安装目录（注册表 Uninstall 键 + 常见路径兜底）。
String? detectInstallDir() {
  final combos = [
    (true, false),
    (true, true),
    (false, false),
    (false, true),
  ];
  for (final (currentUser, wow32) in combos) {
    final dir = findUninstallLocation(
      currentUser: currentUser,
      wow32: wow32,
      nameContains: 'trae',
      excludeContains: ['solo', 'work'],
    );
    if (dir != null && File('$dir\\resources\\app\\product.json').existsSync()) {
      return dir;
    }
  }
  final localApp = Platform.environment['LOCALAPPDATA'] ?? '';
  final fallbacks = [
    '$localApp\\Programs\\Trae CN',
    r'C:\Program Files\Trae CN',
    r'C:\Program Files (x86)\Trae CN',
  ];
  for (final fb in fallbacks) {
    if (fb.length > 3 && File('$fb\\resources\\app\\product.json').existsSync()) {
      return fb;
    }
  }
  return null;
}

/// 从安装目录 product.json 探测 IDE 版本头；(version, versionCode)。
(String, String)? detectIdeVersion() {
  final dir = detectInstallDir();
  if (dir == null) return null;
  final text = _readTextFile('$dir\\resources\\app\\product.json', maxBytes: 16 * 1024 * 1024);
  if (text.isEmpty) return null;
  try {
    final j = jsonDecode(text);
    final av = j['appVersion'];
    if (av is! String || av.isEmpty) return null;
    var code = '';
    final dt = j['date'];
    if (dt is String && dt.length >= 10) {
      final digits = dt.substring(0, 10).replaceAll(RegExp(r'\D'), '');
      if (digits.length == 8) code = digits;
    }
    return (av, code);
  } catch (_) {
    return null;
  }
}
