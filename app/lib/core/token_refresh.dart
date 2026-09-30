// token_refresh.dart - ExchangeToken 刷新流程（对应 C++ accounts/TokenRefresh.cpp）。

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth.dart';

bool needsRefresh(AuthData auth, int nowSec) {
  if (auth.refreshToken.isEmpty) return false;
  if (auth.expiredTs == 0) return false; // 未知过期时间，不主动刷
  return nowSec >= auth.expiredTs - 1800;
}

String? _findStrDeep(dynamic j, List<String> keys, [int depth = 0]) {
  if (depth > 4) return null;
  if (j is Map) {
    for (final k in keys) {
      final v = j[k];
      if (v is String && v.isNotEmpty) return v;
    }
    for (final v in j.values) {
      if (v is Map || v is List) {
        final r = _findStrDeep(v, keys, depth + 1);
        if (r != null && r.isNotEmpty) return r;
      }
    }
  } else if (j is List) {
    for (final v in j) {
      if (v is Map || v is List) {
        final r = _findStrDeep(v, keys, depth + 1);
        if (r != null && r.isNotEmpty) return r;
      }
    }
  }
  return null;
}

class RefreshResult {
  bool ok = false;
  String error = '';
  AuthData? auth;
}

Future<RefreshResult> exchangeToken(AuthData auth) async {
  final rr = RefreshResult();
  if (auth.refreshToken.isEmpty) {
    rr.error = '无 refreshToken，无法刷新';
    return rr;
  }
  var host = auth.host.isEmpty ? 'https://api.trae.cn' : auth.host;
  // CN 版本 host 若指向 mchost.guru 则强制走 api.trae.cn（网关不做 OAuth）
  if (host.contains('mchost.guru')) host = 'https://api.trae.cn';
  while (host.endsWith('/')) {
    host = host.substring(0, host.length - 1);
  }
  final url = '$host/cloudide/api/v3/trae/oauth/ExchangeToken';

  final body = jsonEncode({
    'ClientID': auth.clientId.isEmpty ? 'ono9krqynydwx5' : auth.clientId,
    'RefreshToken': auth.refreshToken,
    'ClientSecret': '-',
    'UserID': auth.userId,
  });

  try {
    final resp = await http
        .post(Uri.parse(url), headers: const {'Content-Type': 'application/json'}, body: body)
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      rr.error = 'HTTP ${resp.statusCode}: ${utf8.decode(resp.bodyBytes, allowMalformed: true)}';
      return rr;
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map) {
      rr.error = '响应非法 JSON';
      return rr;
    }
    final errMeta = decoded['ResponseMetadata'];
    if (errMeta is Map) {
      final e = errMeta['Error'];
      if (e is Map) {
        final code = e['Code'];
        final msg = e['Message'];
        if ((code != null && code != false) || (msg != null && msg != false)) {
          rr.error = '上游错误: ${jsonEncode(e)}';
          return rr;
        }
      }
    }
    var src = decoded['Result'];
    if (src is! Map) src = decoded['result'];
    if (src is! Map) src = decoded;

    final newToken = _findStrDeep(src, ['Token', 'token', 'AccessToken', 'accessToken']);
    if (newToken == null || newToken.isEmpty) {
      rr.error = '响应缺 Token';
      return rr;
    }
    final merged = AuthData()
      ..raw = auth.raw
      ..psd.addAll(auth.psd)
      ..accessToken = newToken
      ..refreshToken = auth.refreshToken
      ..userId = auth.userId
      ..expiredRaw = auth.expiredRaw
      ..expiredTs = auth.expiredTs
      ..host = auth.host
      ..clientId = auth.clientId;
    final newRt = _findStrDeep(src, ['RefreshToken', 'refreshToken']);
    if (newRt != null && newRt.isNotEmpty) merged.refreshToken = newRt;
    final exp = _findStrDeep(src, ['TokenExpireAt', 'tokenExpireAt', 'expiredAt']);
    if (exp != null && exp.isNotEmpty) {
      merged.expiredRaw = exp;
      merged.expiredTs = _parseExpiryLocal(exp);
    }
    rr.auth = merged;
    rr.ok = true;
    return rr;
  } catch (e) {
    rr.error = '网络错误: $e';
    return rr;
  }
}

// parseExpiry 定义在 storage.dart；为避免循环依赖在这里复制精简实现。
int _parseExpiryLocal(String raw) {
  if (raw.isEmpty) return 0;
  final numV = double.tryParse(raw);
  if (numV != null && numV > 0) {
    var v = numV;
    if (v > 1e12) v /= 1000.0;
    return v.toInt();
  }
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})').firstMatch(raw);
  if (m != null) {
    var utc = DateTime.utc(int.parse(m.group(1)!), int.parse(m.group(2)!),
        int.parse(m.group(3)!), int.parse(m.group(4)!), int.parse(m.group(5)!),
        int.parse(m.group(6)!));
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
