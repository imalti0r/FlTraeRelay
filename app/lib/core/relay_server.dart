// relay_server.dart - 内嵌 HTTP 服务器：路由、鉴权、CORS、OpenAI 兼容 API。
// /v1/chat/completions 完整支持（流式/非流式/工具调用/stop 过滤）；
// /v1/responses 提供基础兼容（文本输入输出、SSE、usage；previous_response_id
// 与自定义工具暂未支持）。对应 C++ src/api/Facade.cpp。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'account_pool.dart';
import 'auth.dart';
import 'crypto_x.dart';
import 'model_caps.dart';
import 'model_catalog.dart';
import 'upstream.dart';

class RelaySettings {
  String host = '127.0.0.1';
  int port = 8317;
  bool allowLan = false;
  String apiKey = '';
  bool allowAnyApiKey = false;
  bool defaultStream = false;
  String defaultReasoningEffort = '';
  int defaultIsMaxMode = 0;
  int defaultMaxContextWindow = 0;
  String ideVersion = '';
  String ideVersionCode = '';
  String logLevel = 'info';
  bool loggingEnabled = true;
}

/// 串行化 SSE 写入器：对应 C++ writeSse→sendAll 的同步直发语义。
///
/// 两个关键点（都踩过坑）：
/// 1. `HttpResponse.bufferOutput` 默认 true，数据会缓冲到 close() 才发，
///    必须置 false 才能逐帧送达（否则客户端看起来"卡住"）。
/// 2. Dart 的 StreamSink 禁止并发写入：多个来源（流式回调、心跳 Timer）
///    同时 write/flush 会抛 "StreamSink is bound to a stream"。
///    这里用一条 Future 链把所有写入串起来，保证顺序且不并发。
class SseWriter {
  SseWriter(this._sink);

  final HttpResponse _sink;
  Future<void> _chain = Future<void>.value();
  var _closed = false;

  /// 排队写入一帧。返回的 Future 在该帧真正写出后完成。
  Future<void> write(String data) {
    if (_closed) return Future<void>.value();
    _chain = _chain.then((_) async {
      if (_closed) return;
      try {
        _sink.write(data);
        await _sink.flush();
      } catch (_) {
        // 客户端已断开：后续写入静默丢弃
        _closed = true;
      }
    });
    return _chain;
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await _chain;
      await _sink.close();
    } catch (_) {}
  }
}

class ResolvedSettings {
  String requested = '';
  String configName = '';
  String displayName = '';
  String effort = '';
  bool maxMode = false;
  int window = 0;
}

class RelayServer {
  RelayServer({required this.pool, required this.catalog, required this.settings});

  /// 调试扩展回调：由宿主（AppState）注入，key → JSON 值。
  /// GET  /v1/debug/<key>     取数据
  /// POST /v1/debug/<key>     执行动作（body 作参数）
  Map<String, Future<Map<String, dynamic>> Function(Map<String, dynamic> args)>? debugHandlers;
  Map<String, Map<String, dynamic> Function()>? debugGetters;

  final AccountPool pool;
  final ModelCatalog catalog;
  RelaySettings settings;

  HttpServer? _server;
  final DateTime _startedAt = DateTime.now();
  bool get running => _server != null;

  /// 状态快照（给 /v1/status）。
  Map<String, dynamic> statusJson() => {
        'service': {
          'host': settings.host,
          'port': settings.port,
          'allowLan': settings.allowLan,
        },
        'settings': {
          'reasoningEffort':
              settings.defaultReasoningEffort.isEmpty ? null : settings.defaultReasoningEffort,
          'isMaxMode': settings.defaultIsMaxMode,
        },
        'accounts': [
          for (final a in pool.accounts)
            {
              'nickname': a.nickname,
              'edition': a.editionId,
              'credits': a.credits,
              'active': a.active,
              'lastUsed': a.lastUsedTs,
            }
        ],
      };

  Future<void> start() async {
    if (_server != null) return;
    final host = settings.allowLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
    _server = await HttpServer.bind(host, settings.port);
    _server!.listen(_onRequest, onError: (Object e) {});
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  // ---------- 路由 ----------

  Future<void> _onRequest(HttpRequest req) async {
    final p = req.uri.path;
    try {
      if (p == '/health') {
        _json(req, 200, {'status': 'ok', 'time': DateTime.now().millisecondsSinceEpoch ~/ 1000});
        return;
      }
      if (req.method == 'OPTIONS' &&
          p.startsWith('/v1/')) {
        req.response.statusCode = 200;
        _setCors(req);
        await req.response.close();
        return;
      }
      if (!_checkAuth(req)) {
        _jsonError(req, 401, 'authentication_error', 'API Key 无效', 'invalid_api_key');
        return;
      }
      if (p.startsWith('/v1/debug/')) {
        await _handleDebug(req, p.substring('/v1/debug/'.length));
        return;
      }
      if (req.method == 'GET' && p == '/v1/models') {
        await _handleModels(req);
      } else if (req.method == 'GET' && p == '/v1/status') {
        await catalog.waitFirstAttempt();
        _json(req, 200, statusJson());
      } else if (req.method == 'POST' && p == '/v1/chat/completions') {
        await _handleChatCompletions(req);
      } else if (req.method == 'POST' && p == '/v1/responses') {
        await _handleResponses(req);
      } else {
        _jsonError(req, 404, 'invalid_request_error', '未知路径: $p');
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('[relay] 请求处理异常: $e\n$st');
      if (!req.response.headers.contentType.toString().contains('event-stream')) {
        try {
          _jsonError(req, 500, 'api_error', '内部错误: $e');
        } catch (_) {}
      } else {
        try {
          await req.response.close();
        } catch (_) {}
      }
    }
  }

  void _setCors(HttpRequest req) {
    req.response.headers
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Authorization, Content-Type, X-API-Key')
      ..set('Access-Control-Max-Age', '600')
      ..set('Vary', 'Access-Control-Request-Headers');
  }

  bool _checkAuth(HttpRequest req) {
    if (settings.allowAnyApiKey) return true;
    if (settings.apiKey.isEmpty) return false;
    final auth = req.headers.value('authorization');
    if (auth != null) {
      var v = auth;
      if (v.startsWith('Bearer ')) v = v.substring(7);
      if (v.trim() == settings.apiKey) return true;
    }
    final ak = req.headers.value('x-api-key');
    return ak != null && ak == settings.apiKey;
  }

  void _json(HttpRequest req, int status, Map<String, dynamic> body) {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    req.response.close();
  }

  void _jsonError(HttpRequest req, int status, String type, String message, [String? code]) {
    final err = <String, dynamic>{
      'message': message,
      'type': type,
      ?'code': code,
    };
    _json(req, status, {'error': err});
  }

  // ---------- /v1/debug/*（调试 API，需鉴权） ----------

  /// GET  /v1/debug/usage?date=YYYY-MM-DD   指定日使用记录
  /// GET  /v1/debug/detail?date=&time=      某条记录的完整消息与回答
  /// GET  /v1/debug/status        综合运行状态（服务/账号/模型数/今日用量）
  /// GET  /v1/debug/config        当前 config.json 内容（apiKey 打码）
  /// GET  /v1/debug/models        模型目录（含能力细节）
  /// GET  /v1/debug/usage?date=YYYY-MM-DD   指定日使用记录
  /// GET  /v1/debug/detail?date=&time=      某条记录的完整消息与回答
  /// POST /v1/debug/checkin       全账号签到
  /// POST /v1/debug/refresh-credits 刷新积分
  /// POST /v1/debug/echo          回显请求体（连通性测试）
  Future<void> _handleDebug(HttpRequest req, String key) async {
    // --- 纯读取（走 debugGetters）---
    if (req.method == 'GET') {
      if (key == 'usage') {
        final dateStr = req.uri.queryParameters['date'];
        final day = dateStr != null ? DateTime.tryParse(dateStr) : DateTime.now();
        if (day == null) {
          _jsonError(req, 400, 'invalid_request_error', 'date 格式应为 YYYY-MM-DD');
          return;
        }
        final records = pool.usagePage(day);
        _json(req, 200, {
          'date': dateStr ?? DateTime.now().toIso8601String().substring(0, 10),
          'count': records.length,
          'records': [
            for (final r in records)
              {
                'time': r.ts.toIso8601String(),
                'account': r.account,
                'model': r.model,
                'endpoint': r.endpoint,
                'tokensIn': r.input,
                'tokensOut': r.output,
                'cache': r.cache,
                'creditsDelta': r.creditsDelta,
                'creditsKnown': r.creditsKnown,
                'ms': r.ms,
                'ok': r.ok,
                'hasDetail': r.detailFile.isNotEmpty,
                if (r.detailFile.isNotEmpty) 'detail': r.detailFile,
              }
          ],
        });
        return;
      }
      if (key == 'detail') {
        final dateStr = req.uri.queryParameters['date'] ?? '';
        final timeStr = req.uri.queryParameters['time'] ?? '';
        if (dateStr.isEmpty || timeStr.isEmpty) {
          _jsonError(req, 400, 'invalid_request_error', '需提供 date=YYYY-MM-DD 与 time=HHmmss');
          return;
        }
        final detail = pool.readDetailByPointer(dateStr, timeStr);
        if (detail == null) {
          _jsonError(req, 404, 'invalid_request_error', '详情不存在：$dateStr/$timeStr');
          return;
        }
        _json(req, 200, detail);
        return;
      }
      if (key == 'status') {
        await catalog.waitFirstAttempt();
        final today = pool.usageToday();
        _json(req, 200, {
          ...statusJson(),
          'models': catalog.cached.length,
          'catalogError': catalog.cacheError.isEmpty ? null : catalog.cacheError,
          'today': {'requests': today.requests, 'tokens': today.tokens, 'credits': today.credits},
          'uptimeSec': DateTime.now().difference(_startedAt).inSeconds,
        });
        return;
      }
      final getter = debugGetters?[key];
      if (getter != null) {
        _json(req, 200, getter());
        return;
      }
      _jsonError(req, 404, 'invalid_request_error', '未知调试键: $key');
      return;
    }
    // --- 动作（走 debugHandlers）---
    if (req.method == 'POST') {
      final bodyText = await utf8.decoder.bind(req).join();
      Map<String, dynamic> args = {};
      if (bodyText.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(bodyText);
          if (decoded is Map<String, dynamic>) args = decoded;
        } catch (_) {}
      }
      final handler = debugHandlers?[key];
      if (handler != null) {
        try {
          _json(req, 200, await handler(args));
        } catch (e) {
          _jsonError(req, 500, 'api_error', '调试动作失败: $e');
        }
        return;
      }
      _jsonError(req, 404, 'invalid_request_error', '未知调试动作: $key');
      return;
    }
    _jsonError(req, 405, 'invalid_request_error', '方法不允许');
  }

  // ---------- /v1/models ----------

  Future<void> _handleModels(HttpRequest req) async {
    await catalog.waitFirstAttempt();
    final acc = await pool.acquire(const Duration(seconds: 8));
    if (acc == null) {
      _jsonError(req, 503, 'api_error', pool.hasUsableAccount ? '账号并发繁忙，请稍后重试' : '无可用账号');
      return;
    }
    final data = <Map<String, dynamic>>[];
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final c in catalog.cached) {
      data.add({
        'id': c.configName,
        'object': 'model',
        'created': now,
        'owned_by': 'trae',
        'display_name': c.displayName.isEmpty ? c.configName : c.displayName,
        'max_mode': c.maxMode,
        'context_window_size': {
          'default': c.cwDefault,
          'max': c.cwMax,
        },
        'reasoning_effort_options': [...c.effortOptions, ...c.effortOptionsExt],
        'multimodal': c.vision,
      });
    }
    pool.release(acc, true, 0);
    _json(req, 200, {
      'object': 'list',
      'data': data,
      if (catalog.cacheError.isNotEmpty) 'warning': catalog.cacheError,
    });
  }

  // ---------- 设置解析 ----------

  /// 解析模型与档位设置。返回 (caps, rs, error)；error 非空表示失败。
  (ModelCaps, ResolvedSettings, String) _resolveSettings(
      Account acc, String requested, String effortOverride, int maxOverride) {
    final caps = catalog.get(requested);
    if (caps == null) {
      return (caps ?? ModelCaps(), ResolvedSettings(), '模型不存在或账号不可用: $requested');
    }
    if (!caps.present) {
      return (caps, ResolvedSettings(), '模型不在账号模型表中: $requested');
    }
    final rs = ResolvedSettings()
      ..requested = requested
      ..configName = caps.configName
      ..displayName = caps.displayName.isEmpty ? caps.configName : caps.displayName;
    var wantEffort = effortOverride;
    if (wantEffort.isEmpty) wantEffort = settings.defaultReasoningEffort;
    rs.effort = clampEffort(caps, wantEffort);
    final wantMax = maxOverride > 0 || (maxOverride < 0 && settings.defaultIsMaxMode != 0);
    final (effective, window) = clampMaxMode(caps, wantMax, settings.defaultMaxContextWindow);
    rs.maxMode = effective;
    rs.window = window;
    return (caps, rs, '');
  }

  // ---------- OpenAI 请求解析 ----------

  List<ToolDef> _normalizeTools(dynamic toolsArr, dynamic toolChoice) {
    final out = <ToolDef>[];
    if (toolsArr is List) {
      for (final t in toolsArr) {
        if (t is! Map) continue;
        final type = t['type']?.toString() ?? 'function';
        if (type != 'function') continue;
        final fn = t['function'];
        ToolDef d;
        if (fn is Map) {
          d = ToolDef(
            name: fn['name']?.toString() ?? '',
            description: fn['description']?.toString() ?? '',
            parameters: fn['parameters'] == null ? '{}' : jsonEncode(fn['parameters']),
          );
        } else {
          d = ToolDef(
            name: t['name']?.toString() ?? '',
            description: t['description']?.toString() ?? '',
            parameters: t['parameters'] == null ? '{}' : jsonEncode(t['parameters']),
          );
        }
        if (d.name.isNotEmpty) out.add(d);
      }
    }
    if (toolChoice is String) {
      if (toolChoice == 'none') out.clear();
    } else if (toolChoice is Map) {
      final fn = toolChoice['function'];
      String name = '';
      if (fn is Map) {
        name = fn['name']?.toString() ?? '';
      } else {
        final ty = toolChoice['type']?.toString() ?? '';
        if (ty == 'function' || ty.isEmpty) name = toolChoice['name']?.toString() ?? '';
      }
      if (name.isNotEmpty) out.retainWhere((d) => d.name == name);
    }
    return out;
  }

  /// 上游错误码 → 下游状态/类型。
  (int, String) _upstreamErrorType(UpResult r) {
    if (r.code == 1001 || r.httpStatus == 401) return (401, 'authentication_error');
    if (r.code == 1005) return (403, 'insufficient_quota');
    if (r.code == 429 || r.code == 4008 || r.code == 4011 || r.httpStatus == 429) {
      return (429, 'rate_limit_error');
    }
    if (r.code == 4001) return (400, 'invalid_request_error');
    return (502, 'api_error');
  }

  Map<String, dynamic> _usageJson(Map<String, dynamic> u) {
    var pt = (u['prompt_tokens'] as num?)?.toInt() ?? 0;
    var ct = (u['completion_tokens'] as num?)?.toInt() ?? 0;
    if (!u.containsKey('prompt_tokens')) {
      pt = (u['input_tokens'] as num?)?.toInt() ?? 0;
      ct = (u['output_tokens'] as num?)?.toInt() ?? 0;
    }
    return {
      'prompt_tokens': pt,
      'completion_tokens': ct,
      'total_tokens': pt + ct,
      if (u['prompt_tokens_details'] is Map) 'prompt_tokens_details': u['prompt_tokens_details'],
      if (u['completion_tokens_details'] is Map)
        'completion_tokens_details': u['completion_tokens_details'],
    };
  }

  // ---------- /v1/chat/completions ----------

  Future<void> _handleChatCompletions(HttpRequest req) async {
    // utf8.decoder 逐块解码，天然处理 TCP 分块切断多字节字符的情况
    final bodyText = await utf8.decoder.bind(req).join();
    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(bodyText);
      if (decoded is! Map<String, dynamic>) throw const FormatException('不是 JSON 对象');
      body = decoded;
    } catch (e) {
      _jsonError(req, 400, 'invalid_request_error', '请求体不是合法 JSON: $e');
      return;
    }
    final model = body['model']?.toString() ?? 'auto';
    final stream = body['stream'] is bool ? body['stream'] as bool : settings.defaultStream;

    final acc = await pool.acquire();
    if (acc == null) {
      _jsonError(req, 503, 'api_error', pool.hasUsableAccount ? '账号并发繁忙，请稍后重试' : '无可用账号（未发现凭证）');
      return;
    }
    await pool.ensureFreshToken(acc);

    final (caps, rs, resolveErr) = _resolveSettings(acc, model,
        body['reasoning_effort']?.toString() ?? '',
        body['is_max_mode'] is num ? (body['is_max_mode'] as num).toInt() : -1);
    if (resolveErr.isNotEmpty) {
      pool.release(acc, false, 0);
      _jsonError(req, 400, 'invalid_request_error', resolveErr);
      return;
    }

    // 消息转换
    final messages = <ChatMessage>[];
    final arr = body['messages'];
    if (arr is! List || arr.isEmpty) {
      pool.release(acc, false, 0);
      _jsonError(req, 400, 'invalid_request_error', 'messages 不能为空');
      return;
    }
    for (final m in arr) {
      if (m is! Map) continue;
      final cm = ChatMessage(role: m['role']?.toString() ?? 'user');
      final c = m['content'];
      if (c is String) {
        cm.content = c;
      } else if (c is List) {
        var hasImage = false;
        for (final part in c) {
          if (part is! Map) continue;
          final pt = part['type']?.toString() ?? 'text';
          if (pt == 'text' || pt == 'input_text' || pt == 'output_text') {
            final tx = part['text']?.toString() ?? '';
            cm.content += tx;
            cm.parts.add(MessagePart.text(tx));
          } else {
            final url = _partImageUrl(part);
            if (url != null) {
              cm.parts.add(MessagePart.image(url));
              hasImage = true;
            }
          }
        }
        if (!hasImage) {
          // 无图片时退化为纯文本，避免上游对空 parts 的处理差异
          cm.parts.clear();
        }
      }
      final tcs = m['tool_calls'];
      if (tcs is List) {
        for (final tc in tcs) {
          if (tc is! Map) continue;
          final fn = tc['function'];
          final t = ToolCall(id: tc['id']?.toString() ?? '');
          if (fn is Map) {
            t.name = fn['name']?.toString() ?? '';
            final args = fn['arguments'];
            t.arguments = args is String ? args : (args == null ? '' : jsonEncode(args));
          }
          if (t.name.isNotEmpty) cm.toolCalls.add(t);
        }
      }
      if (cm.role == 'tool') {
        cm.toolCallId = m['tool_call_id']?.toString() ?? '';
        cm.toolName = m['name']?.toString() ?? '';
      }
      messages.add(cm);
    }
    final tools = _normalizeTools(body['tools'], body['tool_choice']);

    // stop 本地过滤
    final stops = <String>[];
    final stopField = body['stop'];
    void addStop(String s) {
      if (s.isNotEmpty && s.length <= 1024 && stops.length < 4) stops.add(s);
    }
    if (stopField is String) addStop(stopField);
    if (stopField is List) {
      for (final s in stopField) {
        if (s is String) addStop(s);
      }
    }
    var includeUsage = false;
    final so = body['stream_options'];
    if (so is Map && so['include_usage'] == true) includeUsage = true;

    final chunkId = 'chatcmpl-${genUuid()}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final modelName = rs.displayName.isEmpty ? rs.configName : rs.displayName;
    final usageStart = DateTime.now();

    Map<String, dynamic> chunkHead() => {
          'id': chunkId,
          'object': 'chat.completion.chunk',
          'created': created,
          'model': modelName,
        };

    final sse = SseWriter(req.response);
    final allText = StringBuffer();
    final allReason = StringBuffer();
    final finalTools = <_ToolAcc>[];
    final stopF = StopFilter(stops);

    bool emitTextDelta(String t) {
      if (t.isEmpty) return true;
      final head = chunkHead()
        ..['choices'] = [
          {
            'index': 0,
            'delta': {'content': t},
            'finish_reason': null,
          }
        ];
      if (includeUsage) head['usage'] = null;
      sse.write('data: ${jsonEncode(head)}\n\n');
      return true;
    }

    if (stream) {
      // bufferOutput 默认 true 会把数据缓冲到 close() 才发送，导致流式
      // 帧全部堆积在结束时一次性下发（客户端表现为"卡住"）。必须关闭，
      // 让每帧立即写出（chunked）。
      req.response.bufferOutput = false;
      req.response.statusCode = 200;
      req.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set('Cache-Control', 'no-cache')
        ..set('Connection', 'keep-alive');
      // 首帧 role
      final roleHead = chunkHead()
        ..['choices'] = [
          {
            'index': 0,
            'delta': {'role': 'assistant', 'content': ''},
            'finish_reason': null,
          }
        ];
      if (includeUsage) roleHead['usage'] = null;
      sse.write('data: ${jsonEncode(roleHead)}\n\n');
    }

    var clientGone = false;

    // SSE 空闲心跳：上游思考/排队期间长时间无 delta 时，向客户端发送
    // SSE 注释行（SSE 规范要求客户端忽略），防止客户端或中间层超时断开。
    Timer? heartbeat;
    var lastWrite = DateTime.now();
    if (stream) {
      heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
        if (clientGone) return;
        if (DateTime.now().difference(lastWrite).inSeconds >= 15) {
          sse.write(': keep-alive\n\n');
        }
      });
    }

    final result = await _runChatPipeline(
      acc,
      caps,
      rs,
      messages,
      tools,
      client: http.Client(),
      sink: (e) {
        lastWrite = DateTime.now();
        if (e.type == UpEventType.text) {
          final vis = stopF.feed(e.text);
          if (vis == null || vis.isEmpty) return true;
          if (!stream) allText.write(vis);
          if (stream && !emitTextDelta(vis)) {
            clientGone = true;
            return false;
          }
          return true;
        }
        if (e.type == UpEventType.reason) {
          if (!stream) allReason.write(e.text);
          if (stream) {
            final head = chunkHead()
              ..['choices'] = [
                {
                  'index': 0,
                  'delta': {'reasoning_content': e.text},
                  'finish_reason': null,
                }
              ];
            if (includeUsage) head['usage'] = null;
            sse.write('data: ${jsonEncode(head)}\n\n');
          }
          return true;
        }
        if (e.type == UpEventType.toolCall) {
          final tail = stopF.flush();
          if (tail != null && tail.isNotEmpty) {
            if (!stream) allText.write(tail);
            if (stream && !emitTextDelta(tail)) {
              clientGone = true;
              return false;
            }
          }
          _accumulateTool(finalTools, e);
          if (!stream) return true;
          final head = chunkHead()
            ..['choices'] = [
              {
                'index': 0,
                'delta': {
                  'tool_calls': [
                    {
                      'index': e.toolIndex >= 0 ? e.toolIndex : 0,
                      if (e.toolId.isNotEmpty) 'id': e.toolId,
                      'type': 'function',
                      'function': {
                        if (e.toolName.isNotEmpty) 'name': e.toolName,
                        'arguments': e.toolArgs,
                      },
                    }
                  ],
                },
                'finish_reason': null,
              }
            ];
          if (includeUsage) head['usage'] = null;
          sse.write('data: ${jsonEncode(head)}\n\n');
          return true;
        }
        return true;
      },
    );

    // stop 过滤器残余冲刷
    if (result.ok || result.clientAborted) {
      final tail = stopF.flush();
      if (tail != null && tail.isNotEmpty) {
        if (!stream) allText.write(tail);
        if (stream && !emitTextDelta(tail)) clientGone = true;
      }
    }

    void recordUsage(bool ok) {
      if (!ok) return;
      var inT = 0, outT = 0, cacheT = 0;
      final u = result.usage;
      if (u != null) {
        inT = (u['prompt_tokens'] as num?)?.toInt() ?? 0;
        outT = (u['completion_tokens'] as num?)?.toInt() ?? 0;
        final pd = u['prompt_tokens_details'];
        if (pd is Map) cacheT = (pd['cached_tokens'] as num?)?.toInt() ?? 0;
      }
      if (inT > 0 || outT > 0) {
        final ms = DateTime.now().difference(usageStart).inMilliseconds;
        pool.usageRecordPending(acc, caps, '/v1/chat/completions', inT, outT, cacheT, ms, {
          'messages': [
            for (final m in messages)
              {
                'role': m.role,
                'content': m.content,
                if (m.toolCallId.isNotEmpty) 'tool_call_id': m.toolCallId,
                if (m.toolCalls.isNotEmpty)
                  'tool_calls': [
                    for (final t in m.toolCalls)
                      {'id': t.id, 'name': t.name, 'arguments': t.arguments},
                  ],
              }
          ],
          'tools': [for (final t in tools) t.name],
          'reasoning': allReason.toString(),
          'text': allText.toString(),
          'toolCalls': [
            for (final t in finalTools) {'id': t.id, 'name': t.name, 'arguments': t.args},
          ],
          'finishReason': result.finishReason,
        });
      }
    }

    if (!result.ok && !result.clientAborted) {
      // 上游失败
      recordUsage(false);
      pool.release(acc, false, result.code);
      heartbeat?.cancel();
      final (httpErr, type) = _upstreamErrorType(result);
      final msg = result.error.isEmpty ? '上游请求失败' : result.error;
      if (stream) {
        if (!clientGone) {
          final errFrame = {
            'error': {
              'message': msg,
              'type': type,
              if (result.code != 0) 'code': result.code.toString(),
            }
          };
          sse.write('event: error\ndata: ${jsonEncode(errFrame)}\n\n');
          sse.write('data: [DONE]\n\n');
        }
        await sse.close();
      } else {
        _jsonError(req, httpErr, type, msg);
      }
      return;
    }

    heartbeat?.cancel();
    recordUsage(true);
    pool.release(acc, true, 0);
    if (result.ok) {
      // 消耗不随聊天流下发，请求后异步补查积分
      unawaited(pool.refreshCredits(acc));
    }

    if (stream) {
      if (!clientGone) {
        var fr = result.finishReason.isEmpty ? 'stop' : result.finishReason;
        if (stopF.hit) {
          fr = 'stop';
        } else if (fr != 'length' && fr != 'content_filter' && finalTools.isNotEmpty) {
          fr = 'tool_calls';
        }
        final head = chunkHead()
          ..['choices'] = [
            {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': fr}
          ];
        if (includeUsage) {
          head['usage'] = null;
          sse.write('data: ${jsonEncode(head)}\n\n');
          final uhead = chunkHead()
            ..['choices'] = []
            ..['usage'] = _usageJson(result.usage ?? {});
          sse.write('data: ${jsonEncode(uhead)}\n\n');
        } else {
          if (result.usage != null && result.usage!.isNotEmpty) head['usage'] = _usageJson(result.usage!);
          sse.write('data: ${jsonEncode(head)}\n\n');
        }
        sse.write('data: [DONE]\n\n');
      }
      await sse.close();
      return;
    }

    // 非流式响应
    final msg = <String, dynamic>{'role': 'assistant'};
    if (finalTools.isNotEmpty) {
      msg['content'] = allText.isEmpty ? null : allText.toString();
      msg['tool_calls'] = [
        for (final t in finalTools)
          {
            'id': t.id,
            'type': 'function',
            'function': {'name': t.name, 'arguments': t.args.isEmpty ? '{}' : t.args},
          }
      ];
    } else {
      msg['content'] = allText.toString();
    }
    if (allReason.isNotEmpty) msg['reasoning_content'] = allReason.toString();
    var finishReason = result.finishReason.isEmpty ? 'stop' : result.finishReason;
    if (stopF.hit) {
      finishReason = 'stop';
    } else if (finishReason != 'length' && finishReason != 'content_filter' && finalTools.isNotEmpty) {
      finishReason = 'tool_calls';
    }
    _json(req, 200, {
      'id': chunkId,
      'object': 'chat.completion',
      'created': created,
      'model': modelName,
      'choices': [
        {'index': 0, 'message': msg, 'finish_reason': finishReason}
      ],
      'usage': _usageJson(result.usage ?? {}),
    });
  }

  String? _partImageUrl(Map part) {
    if (part['image_url'] is Map) {
      final iu = part['image_url'] as Map;
      if (iu['url'] is String) return iu['url'] as String;
    }
    if (part['url'] is String) return part['url'] as String;
    if (part['file_id'] is String) return null; // 文件引用暂不支持
    return null;
  }

  // ---------- /v1/responses（基础兼容） ----------

  Future<void> _handleResponses(HttpRequest req) async {
    // utf8.decoder 逐块解码，天然处理 TCP 分块切断多字节字符的情况
    final bodyText = await utf8.decoder.bind(req).join();
    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(bodyText);
      if (decoded is! Map<String, dynamic>) throw const FormatException('不是 JSON 对象');
      body = decoded;
    } catch (e) {
      _jsonError(req, 400, 'invalid_request_error', '请求体不是合法 JSON: $e');
      return;
    }
    final model = body['model']?.toString() ?? 'auto';
    final stream = body['stream'] is bool ? body['stream'] as bool : settings.defaultStream;
    final input = body['input'];
    final messages = <ChatMessage>[];
    // instructions 作为 system
    final instructions = body['instructions'];
    if (instructions is String && instructions.isNotEmpty) {
      messages.add(ChatMessage(role: 'system', content: instructions));
    }
    if (input is String) {
      messages.add(ChatMessage(role: 'user', content: input));
    } else if (input is List) {
      for (final item in input) {
        if (item is! Map) continue;
        final role = item['role']?.toString() ?? 'user';
        final content = item['content'];
        if (content is String) {
          messages.add(ChatMessage(role: role, content: content));
        } else if (content is List) {
          final cm = ChatMessage(role: role);
          for (final part in content) {
            if (part is! Map) continue;
            final pt = part['type']?.toString() ?? '';
            if (pt == 'input_text' || pt == 'output_text' || pt == 'text') {
              final tx = part['text']?.toString() ?? '';
              cm.content += tx;
              cm.parts.add(MessagePart.text(tx));
            } else {
              final url = _partImageUrl(part);
              if (url != null) cm.parts.add(MessagePart.image(url));
            }
          }
          messages.add(cm);
        }
      }
    }
    if (messages.isEmpty) {
      _jsonError(req, 400, 'invalid_request_error', 'input 不能为空');
      return;
    }

    final acc = await pool.acquire();
    if (acc == null) {
      _jsonError(req, 503, 'api_error', pool.hasUsableAccount ? '账号并发繁忙，请稍后重试' : '无可用账号（未发现凭证）');
      return;
    }
    await pool.ensureFreshToken(acc);
    final (caps, rs, resolveErr) = _resolveSettings(acc, model,
        body['reasoning'] is Map ? ((body['reasoning'] as Map)['effort']?.toString() ?? '') : '',
        -1);
    if (resolveErr.isNotEmpty) {
      pool.release(acc, false, 0);
      _jsonError(req, 400, 'invalid_request_error', resolveErr);
      return;
    }
    final responseId = 'resp-${genUuid()}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final allText = StringBuffer();
    final allReason = StringBuffer();
    final usageStart = DateTime.now();

    final sse = SseWriter(req.response);
    if (stream) {
      req.response.bufferOutput = false;
      req.response.statusCode = 200;
      req.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set('Cache-Control', 'no-cache');
    }

    final result = await _runChatPipeline(
      acc,
      caps,
      rs,
      messages,
      _normalizeTools(body['tools'], body['tool_choice']),
      client: http.Client(),
      sink: (e) {
        if (e.type == UpEventType.text) {
          allText.write(e.text);
          if (stream) {
            sse.write('event: response.output_text.delta\ndata: ${jsonEncode({
                  'type': 'response.output_text.delta',
                  'item_id': responseId,
                  'output_index': 0,
                  'content_index': 0,
                  'delta': e.text,
                })}\n\n');
          }
          return true;
        }
        if (e.type == UpEventType.reason) {
          allReason.write(e.text);
          return true;
        }
        return true;
      },
    );

    pool.release(acc, result.ok, result.code);
    if (result.ok) unawaited(pool.refreshCredits(acc));
    var inT = 0, outT = 0, cacheT = 0;
    final u = result.usage;
    if (u != null) {
      inT = (u['prompt_tokens'] as num?)?.toInt() ?? 0;
      outT = (u['completion_tokens'] as num?)?.toInt() ?? 0;
      final pd = u['prompt_tokens_details'];
      if (pd is Map) cacheT = (pd['cached_tokens'] as num?)?.toInt() ?? 0;
    }
    if (result.ok && (inT > 0 || outT > 0)) {
      pool.usageRecordPending(acc, caps, '/v1/responses', inT, outT, cacheT,
          DateTime.now().difference(usageStart).inMilliseconds, {
        'messages': [
          for (final m in messages) {'role': m.role, 'content': m.content},
        ],
        'reasoning': allReason.toString(),
        'text': allText.toString(),
        'finishReason': result.finishReason,
      });
    }

    if (!result.ok && !result.clientAborted) {
      final (httpErr, type) = _upstreamErrorType(result);
      if (stream) await req.response.close();
      _jsonError(req, httpErr, type, result.error.isEmpty ? '上游请求失败' : result.error);
      return;
    }

    final usage = _usageJson(result.usage ?? {});
    if (stream) {
      sse.write('event: response.completed\ndata: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'id': responseId,
              'object': 'response',
              'created_at': created,
              'status': 'completed',
              'model': rs.displayName.isEmpty ? rs.configName : rs.displayName,
              'output_text': allText.toString(),
              'usage': usage,
            },
          })}\n\n');
      await sse.close();
      return;
    }
    _json(req, 200, {
      'id': responseId,
      'object': 'response',
      'created_at': created,
      'status': 'completed',
      'model': rs.displayName.isEmpty ? rs.configName : rs.displayName,
      'output': [
        {
          'type': 'message',
          'id': 'msg-${genUuid()}',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': allText.toString()},
          ],
        }
      ],
      'usage': usage,
      if (allReason.isNotEmpty) 'reasoning_content': allReason.toString(),
    });
  }

  // ---------- 管线 ----------

  Future<UpResult> _runChatPipeline(
    Account acc,
    ModelCaps caps,
    ResolvedSettings rs,
    List<ChatMessage> messages,
    List<ToolDef> tools, {
    required UpSink sink,
    required http.Client client,
  }) async {
    final rq = UpRequest()
      ..model = caps.configName
      ..messages = messages
      ..tools = tools
      ..stream = true
      ..reasoningEffort = rs.effort
      ..maxMode = rs.maxMode
      ..maxContextWindow = rs.window;

    UpSink numberedSink(UpSink inner) {
      var seq = 0;
      return (e) {
        if (e.type == UpEventType.toolCall) {
          final ne = UpEvent.toolCall(
            e.toolId.isEmpty ? 'call_${genUuid()}' : e.toolId,
            e.toolName,
            e.toolArgs.isEmpty ? '{}' : e.toolArgs,
            toolIndex: seq++,
          );
          return inner(ne);
        }
        return inner(e);
      };
    }

    final result = await upstreamSolo(
      rq,
      acc,
      caps,
      sink: numberedSink(sink),
      onUsageEvent: (event) => pool.updateCreditsFromEvent(acc, event),
      ideVersion: settings.ideVersion,
      ideVersionCode: settings.ideVersionCode,
      client: client,
    );
    // 认证失败 → 刷新令牌后重试一次
    if (!result.ok && !result.clientAborted && (result.code == 1001 || result.httpStatus == 401)) {
      await pool.ensureFreshToken(acc);
      return upstreamSolo(
        rq,
        acc,
        caps,
        sink: numberedSink(sink),
        onUsageEvent: (event) => pool.updateCreditsFromEvent(acc, event),
        ideVersion: settings.ideVersion,
        ideVersionCode: settings.ideVersionCode,
        client: client,
      );
    }
    return result;
  }
}

class _ToolAcc {
  String id = '';
  String name = '';
  String args = '';
}

/// 对应 C++ ToolAccumulator：按 toolIndex 分组累积完整工具调用。
void _accumulateTool(List<_ToolAcc> tools, UpEvent e) {
  final idx = e.toolIndex >= 0 ? e.toolIndex : tools.length;
  while (tools.length <= idx) {
    tools.add(_ToolAcc());
  }
  final t = tools[idx];
  if (t.id.isNotEmpty && e.toolId.isNotEmpty && e.toolId != t.id) {
    tools.add(_ToolAcc()
      ..id = e.toolId
      ..name = e.toolName
      ..args = e.toolArgs);
    return;
  }
  if (e.toolId.isNotEmpty) t.id = e.toolId;
  if (e.toolName.isNotEmpty) t.name = e.toolName;
  if (e.toolArgs.isNotEmpty) t.args += e.toolArgs;
}

/// stop 序列本地过滤器：扣住不足一个最长 stop 的尾巴防跨帧命中。
class StopFilter {
  StopFilter(this.stops) {
    for (final s in stops) {
      if (s.length > holdMax) holdMax = s.length;
    }
    if (holdMax > 0) holdMax -= 1;
  }

  final List<String> stops;
  final StringBuffer _pend = StringBuffer();
  int holdMax = 0;
  bool hit = false;

  String? feed(String t) {
    if (hit) return null;
    if (stops.isEmpty) return t;
    _pend.write(t);
    var best = -1;
    for (final s in stops) {
      final p = _pend.toString().indexOf(s);
      if (p >= 0 && (best < 0 || p < best)) best = p;
    }
    if (best >= 0) {
      hit = true;
      final out = _pend.toString().substring(0, best);
      _pend.clear();
      return out;
    }
    final pend = _pend.toString();
    if (pend.length > holdMax) {
      final cut = pend.length - holdMax;
      final out = pend.substring(0, cut);
      _pend.clear();
      _pend.write(pend.substring(cut));
      return out;
    }
    return null;
  }

  String? flush() {
    if (_pend.isEmpty) return null;
    final out = _pend.toString();
    _pend.clear();
    return out;
  }
}
