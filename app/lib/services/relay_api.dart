// relay_api.dart - 后端 HTTP 客户端：/health、/v1/status、/v1/models。
// /health 无需鉴权；其余接口携带 Bearer Key（Key 来自 config.json）。

import 'dart:convert';
import 'dart:io';

import '../models.dart';

class RelayApi {
  RelayApi({required this.host, required this.port, required this.apiKey});

  final String host;
  final int port;
  final String apiKey;

  Uri _uri(String path) => Uri.parse('http://${host == '0.0.0.0' ? '127.0.0.1' : host}:$port$path');

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $apiKey',
        'X-API-Key': apiKey,
      };

  /// 健康检查，无需鉴权。任何网络层错误都归为不可达。
  Future<bool> health() async {
    try {
      final resp = await _uri('/health')
          .get(headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<RelayStatus> status() async {
    final j = await _getJson('/v1/status');
    return RelayStatus.fromJson(j);
  }

  Future<List<ModelInfo>> models() async {
    final j = await _getJson('/v1/models');
    final data = (j['data'] as List?) ?? const [];
    return data
        .whereType<Map>()
        .map((e) => ModelInfo.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
        .toList();
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final resp = await _uri(path)
        .get(headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw HttpException('HTTP ${resp.statusCode}', uri: _uri(path));
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }
}
