// upstream.dart - 上游通道：请求头、思考档位 clamp、Max 模式、solo 聊天
// (/api/agent/v3/llm_utils_chat) 与 SSE 事件解析。对应 C++ Upstream.cpp / UpstreamSolo.cpp。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth.dart';
import 'crypto_x.dart';
import 'model_caps.dart';

const kSoloHost = 'https://trae-api-cn.mchost.guru';

/// 与 Trae IDE 一致的请求头。
Map<String, String> ideHeaders(Account acc, String ideVersion, String ideVersionCode,
    {bool sse = false, String appId = '6eefa01c-1036-4c7e-9ca5-d891f63bfcd8'}) {
  return {
    'Content-Type': 'application/json',
    'Authorization': 'Cloud-IDE-JWT ${acc.auth.accessToken}',
    'X-Cloudide-Token': acc.auth.accessToken,
    'X-Ide-Token': acc.auth.accessToken,
    'X-Uid': acc.auth.userId,
    'x-uid': acc.auth.userId,
    'x-app-id': appId,
    'x-app-version': 'default',
    'x-app-version-code': ideVersionCode,
    'x-device-id': acc.deviceId.isEmpty ? (acc.machineId.isEmpty ? '0' : acc.machineId) : acc.deviceId,
    'x-machine-id': acc.machineId.isEmpty ? '0' : acc.machineId,
    'x-request-id': genUuid(),
    'x-ide-version': ideVersion,
    'x-ide-version-code': ideVersionCode,
    'x-ide-version-type': 'stable',
    'x-device-cpu': 'AMD',
    'x-device-brand': '83DG',
    'x-device-type': 'windows',
    'x-os-version': 'Windows 11 Pro',
    'x-system-type': 'Windows',
    'Accept': sse ? 'text/event-stream' : 'application/json',
    'Connection': 'keep-alive',
  };
}

String _normalizeEffort(String v) => v.trim().toLowerCase();

/// 客户端档位别名 → Trae 原生档位（如 OpenAI 生态的 max → extra_high）。
String? _effortAlias(String v) {
  switch (v) {
    case 'max':
    case 'maximal':
    case 'maximum':
      return 'extra_high';
    case 'minimal':
      return 'low';
    default:
      return null;
  }
}

/// R5：思考档位 clamp（用户意愿 × 模型能力），空串表示不透传。
String clampEffort(ModelCaps caps, String wantRaw) {
  if (wantRaw.isEmpty) {
    if (caps.effortDefault.isNotEmpty && caps.supportThinking) {
      return _normalizeEffort(caps.effortDefault);
    }
    return '';
  }
  if (!caps.supportThinking) return '';
  final want = _effortAlias(_normalizeEffort(wantRaw)) ?? _normalizeEffort(wantRaw);
  if (caps.effortOptions.isEmpty && caps.effortOptionsExt.isEmpty) return '';
  final hasOption = caps.effortOptions.any((o) => _normalizeEffort(o) == want) ||
      caps.effortOptionsExt.any((o) => _normalizeEffort(o) == want);
  return hasOption ? want : '';
}

/// R6：Max 模式 clamp，返回 (是否生效, 上下文窗口)。
(bool, int) clampMaxMode(ModelCaps caps, bool want, int cfgWindow) {
  if (!want || !caps.maxMode) {
    return (false, caps.cwDefault > 0 ? caps.cwDefault : 200000);
  }
  var best = 0;
  for (final v in caps.cwMax) {
    if (cfgWindow > 0 ? (v <= cfgWindow && v > best) : (v > best)) best = v;
  }
  if (best <= 0) best = 1000000;
  return (true, best);
}

// ---------- 请求/事件模型 ----------

class MessagePart {
  MessagePart.text(this.text) : isImage = false, url = '';
  MessagePart.image(this.url) : isImage = true, text = '';
  final bool isImage;
  final String text;
  final String url;
}

class ToolCall {
  ToolCall({this.id = '', this.name = '', this.arguments = ''});
  String id;
  String name;
  String arguments;
}

class ChatMessage {
  ChatMessage({this.role = 'user', this.content = ''});
  String role;
  String content;
  List<MessagePart> parts = [];
  List<ToolCall> toolCalls = [];
  String toolCallId = '';
  String toolName = '';
}

class ToolDef {
  ToolDef({this.name = '', this.description = '', this.parameters = '{}'});
  String name;
  String description;
  String parameters;
}

class UpRequest {
  String model = '';
  List<ChatMessage> messages = [];
  List<ToolDef> tools = [];
  bool stream = true;
  String reasoningEffort = '';
  bool maxMode = false;
  int maxContextWindow = 0;
}

enum UpEventType { text, reason, toolCall }

class UpEvent {
  UpEvent.text(this.text) : type = UpEventType.text, toolIndex = -1, toolId = '', toolName = '', toolArgs = '';
  UpEvent.reason(this.text) : type = UpEventType.reason, toolIndex = -1, toolId = '', toolName = '', toolArgs = '';
  UpEvent.toolCall(this.toolId, this.toolName, this.toolArgs, {this.toolIndex = -1})
      : type = UpEventType.toolCall, text = '';
  final UpEventType type;
  final String text;
  final int toolIndex;
  final String toolId;
  final String toolName;
  final String toolArgs;
}

class UpResult {
  bool ok = false;
  bool clientAborted = false;
  int httpStatus = 0;
  int code = 0;
  String error = '';
  String finishReason = '';
  String model = '';
  Map<String, dynamic>? usage;
}

/// 消息 content parts：文本统一过标签消毒，图片透传。
void _sanitizeToolTags(StringSink out, String text) {
  const from = ['<opencode_tool_call>', '</opencode_tool_call>', '<opencode_tool_result', '</opencode_tool_result'];
  const to = ['<tool_invoke>', '</tool_invoke>', '<tool_result', '</tool_result'];
  for (var i = 0; i < from.length; i++) {
    text = text.replaceAll(from[i], to[i]);
  }
  out.write(text);
}

String _sanitize(String text) {
  final sb = StringBuffer();
  _sanitizeToolTags(sb, text);
  return sb.toString();
}

List<Map<String, dynamic>> _soloContent(ChatMessage m) {
  final arr = <Map<String, dynamic>>[];
  void pushText(String text) {
    final clean = _sanitize(text);
    if (clean.isEmpty) return;
    arr.add({'type': 'text', 'text': clean});
  }

  if (m.parts.isNotEmpty) {
    for (final p in m.parts) {
      if (!p.isImage) {
        pushText(p.text);
      } else if (p.url.isNotEmpty) {
        arr.add({'type': 'image_url', 'image_url': {'url': p.url}});
      }
    }
  } else {
    pushText(m.content);
  }
  return arr;
}

// ---------- 上游 SSE 事件监听 ----------

/// 由调用方实现：返回 false 表示下游中止。
typedef UpSink = bool Function(UpEvent e);

/// token_usage / notify_usage 事件透传给池子更新积分。
typedef UsageListener = void Function(Map<String, dynamic> event);

class _SseFrame {
  _SseFrame(this.event, this.data);
  final String event;
  final String data;
}

/// 增量 SSE 解析器（event:/data: 行 + 空行派发），对应 C++ SseParser。
class SseParser {
  final bool Function(_SseFrame frame) _handler;
  String _event = '';
  String _data = '';
  bool _dead = false;

  SseParser(this._handler);

  void feedLine(String line) {
    if (_dead) return;
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (line.isEmpty) {
      _dispatch();
      return;
    }
    if (line.startsWith(':')) return;
    if (line.startsWith('event:')) {
      var s = 6;
      while (s < line.length && (line[s] == ' ' || line[s] == '\t')) {
        s++;
      }
      _event = line.substring(s);
    } else if (line.startsWith('data:')) {
      var s = 5;
      while (s < line.length && (line[s] == ' ' || line[s] == '\t')) {
        s++;
      }
      if (_data.isNotEmpty) _data += '\n';
      _data += line.substring(s);
    }
  }

  void _dispatch() {
    if (_event.isEmpty && _data.isEmpty) return;
    final ev = _event.isEmpty ? 'message' : _event;
    final d = _data;
    _event = '';
    _data = '';
    if (!_handler(_SseFrame(ev, d))) _dead = true;
  }

  void finish() => _dispatch();
}

/// solo 通道：流式请求上游并解析事件流。返回 UpResult；事件通过 [sink] 下发。
/// [onUsageEvent] 收到 token_usage / notify_usage 事件（供积分回填）。
Future<UpResult> upstreamSolo(
  UpRequest req,
  Account acc,
  ModelCaps caps, {
  required UpSink sink,
  required UsageListener onUsageEvent,
  required String ideVersion,
  required String ideVersionCode,
  required http.Client client,
}) async {
  final r = UpResult();
  final configName = caps.configName.isEmpty ? req.model : caps.configName;

  final messages = <Map<String, dynamic>>[];
  for (final m in req.messages) {
    final role = m.role == 'developer' ? 'system' : m.role;
    if (role == 'tool') {
      messages.add({
        'role': 'tool',
        'tool_call_id': m.toolCallId.isEmpty ? 'unknown' : m.toolCallId,
        if (m.toolName.isNotEmpty) 'name': m.toolName,
        'content': _soloContent(m),
      });
      continue;
    }
    if (role == 'assistant' && m.toolCalls.isNotEmpty) {
      final tcs = <Map<String, dynamic>>[];
      for (final tc in m.toolCalls) {
        if (tc.name.isEmpty) continue;
        tcs.add({
          'id': tc.id.isEmpty ? 'call_${genUuid()}' : tc.id,
          'type': 'function',
          'function_call': {'name': tc.name, 'arguments': tc.arguments.isEmpty ? '{}' : tc.arguments},
        });
      }
      final content = _soloContent(m);
      if (tcs.isEmpty && content.isEmpty) continue;
      messages.add({'role': 'assistant', 'content': content, 'tool_calls': tcs});
      continue;
    }
    final content = _soloContent(m);
    if (content.isEmpty) continue;
    messages.add({'role': role, 'content': content});
  }
  if (messages.isEmpty) {
    messages.add({
      'role': 'user',
      'content': [
        {'type': 'text', 'text': ''}
      ],
    });
  }

  final body = <String, dynamic>{'messages': messages};
  final ideChat = caps.ideChatCapable;
  final ideFunction = caps.ideFunction.isEmpty ? 'chat_v3' : caps.ideFunction;
  body['function'] = ideChat ? ideFunction : 'chat_v3';
  body['stream'] = true;
  body['config_name'] = configName;
  var upstreamModel = caps.modelName;
  if (req.maxMode) {
    if (caps.maxModelName.isNotEmpty) upstreamModel = caps.maxModelName;
    body['mode_type'] = 1;
    body['context_window_size'] = req.maxContextWindow > 0 ? req.maxContextWindow : 1000000;
  }
  final modelName = ideChat && upstreamModel.isNotEmpty ? upstreamModel : configName;
  body['model'] = modelName;
  body['model_name'] = modelName;
  body['config_source'] = caps.configSource;
  body['is_custom_model'] = false;
  body['provider'] = caps.provider;
  if (req.reasoningEffort.isNotEmpty) {
    body['reasoning_effort'] = req.reasoningEffort;
  }
  if (req.tools.isNotEmpty) {
    body['tools'] = [
      for (final td in req.tools)
        {
          'type': 'function',
          'function': {
            'name': td.name,
            'description': td.description,
            'parameters': td.parameters.isEmpty ? '{}' : td.parameters,
          },
        }
    ];
    body['tool_choice'] = 'auto';
  }

  final headers = ideHeaders(acc, ideVersion, ideVersionCode, sse: true);
  http.StreamedResponse resp;
  try {
    final request = http.Request('POST', Uri.parse('$kSoloHost/api/agent/v3/llm_utils_chat'));
    request.headers.addAll(headers);
    request.body = jsonEncode(body);
    resp = await client.send(request).timeout(
          Duration(seconds: caps.ideChatCapable ? 120 : 120),
        );
  } catch (e) {
    r.error = '打开失败: $e';
    return r;
  }
  r.httpStatus = resp.statusCode;
  if (resp.statusCode != 200) {
    var errBody = '';
    try {
      errBody = await resp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .take(20)
          .join('\n');
    } catch (_) {}
    r.code = resp.statusCode == 401 ? 1001 : 0;
    r.error = 'solo chat HTTP ${resp.statusCode}: ${errBody.length > 400 ? errBody.substring(0, 400) : errBody}';
    return r;
  }

  var sawDone = false;
  var aborted = false;
  var queued = false; // 排队状态标记（仅透传信息用）
  final lastResp = SnapshotTracker();
  final lastReason = SnapshotTracker();
  // 原生工具调用增量：按 index 累积，done 时一次性下发
  final nativeTools = <int, _NativeTool>{};
  final completer = Completer<UpResult>();

  bool emit(UpEvent e) {
    if (!sink(e)) {
      aborted = true;
      return false;
    }
    return true;
  }

  bool flushNativeTools() {
    final sorted = nativeTools.keys.toList()..sort();
    for (final idx in sorted) {
      final nt = nativeTools[idx]!;
      if (nt.name.isEmpty) continue;
      if (!emit(UpEvent.toolCall(nt.id, nt.name, nt.args.isEmpty ? '{}' : nt.args, toolIndex: idx))) {
        return false;
      }
    }
    return true;
  }

  final parser = SseParser((frame) {
    var ev = frame.event.toLowerCase();
    if (ev == 'request_wait_in_queue' || ev == 'queue_begin') {
      queued = true;
      return true;
    }
    if (ev == 'queue_end') {
      queued = false;
      return true;
    }
    if (ev == 'done' || ev == 'error' || frame.data == '[DONE]') queued = false;
    if (frame.data == '[DONE]') {
      sawDone = true;
      return false;
    }
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(frame.data);
      if (decoded is! Map<String, dynamic>) return true;
      data = decoded;
    } catch (_) {
      return true;
    }
    if (ev == 'error') {
      r.code = (data['code'] as num?)?.toInt() ?? 0;
      r.error = 'trae ${r.code}: ${data['message'] ?? ''}';
      return false;
    }
    if (ev == 'token_usage' || ev == 'notify_usage' || ev == 'usage') {
      final u = data['usage'];
      if (u is Map<String, dynamic>) {
        r.usage = u;
      } else {
        final pt = (data['prompt_tokens'] as num?)?.toInt() ?? 0;
        final ct = (data['completion_tokens'] as num?)?.toInt() ?? 0;
        var tt = (data['total_tokens'] as num?)?.toInt() ?? 0;
        if (tt == 0) tt = pt + ct;
        if (pt > 0 || ct > 0 || tt > 0) {
          r.usage = {
            'prompt_tokens': pt,
            'completion_tokens': ct,
            'total_tokens': tt,
            'prompt_tokens_details': {
              'cached_tokens': (data['cache_read_input_tokens'] as num?)?.toInt() ?? 0,
              'cache_creation_input_tokens': (data['cache_creation_input_tokens'] as num?)?.toInt() ?? 0,
            },
            'completion_tokens_details': {
              'reasoning_tokens': (data['reasoning_tokens'] as num?)?.toInt() ?? 0,
            },
          };
        }
      }
      onUsageEvent(data);
      return true;
    }
    if (ev == 'progress_notice' || ev == 'metadata' || ev == 'extra_info' || ev == 'timing_cost') {
      return true;
    }
    if (ev == 'done') {
      if (!flushNativeTools()) return false;
      final fr = data['finish_reason'];
      r.finishReason = fr is String && fr.isNotEmpty ? fr : 'stop';
      sawDone = true;
      return false;
    }
    if (ev == 'output' || ev == 'message' || ev == 'text') {
      // 原生工具调用（流式增量）
      final tcs = data['tool_calls'];
      if (tcs is List) {
        for (var i = 0; i < tcs.length; i++) {
          final tc = tcs[i];
          if (tc is! Map) continue;
          final idx = (tc['index'] as num?)?.toInt() ?? i;
          final id = tc['id']?.toString() ?? '';
          String name;
          String argsField;
          String partialField;
          final fc = tc['function_call'];
          if (fc is Map) {
            name = fc['name']?.toString() ?? '';
            argsField = fc['arguments']?.toString() ?? '';
            partialField = fc['partial_arguments']?.toString() ?? '';
          } else {
            final fn = tc['function'];
            if (fn is Map) {
              name = fn['name']?.toString() ?? '';
              argsField = fn['arguments']?.toString() ?? '';
              partialField = fn['partial_arguments']?.toString() ?? '';
            } else {
              name = '';
              argsField = '';
              partialField = '';
            }
          }
          final nt = nativeTools.putIfAbsent(idx, () => _NativeTool());
          if (id.isNotEmpty) nt.id = id;
          if (name.isNotEmpty) nt.name = name;
          if (partialField.isNotEmpty) {
            nt.args += partialField;
          } else if (argsField.isNotEmpty) {
            if (nt.args.isEmpty) {
              nt.args = argsField;
            } else if (argsField.length >= nt.args.length &&
                argsField.startsWith(nt.args)) {
              nt.args = argsField; // 累计快照
            } else if (argsField == nt.args) {
              // 重复快照，忽略
            } else {
              nt.args += argsField; // 增量片段
            }
          }
        }
      }
      // 正文/思考字段的语义随上游版本而变，这里用"增量优先 + 快照兜底"判定：
      // 实测（2026-09-30）glm-5.3 等模型的 response / reasoning_content 都是
      // 纯增量片段（如 "The" / " user" / " is"），若按累计快照处理会把绝大多数
      // 片段当"变短"丢弃，表现为内容只显示开头一小段。
      // 判定规则：若新串以已累计内容为前缀且更长 → 按快照取差值；
      // 否则按增量直接追加。
      final txt = data['content'];
      if (txt is String && txt.isNotEmpty) {
        if (!emit(UpEvent.text(txt))) return false;
      }
      final respText = data['response'];
      if (respText is String && respText.isNotEmpty) {
        final delta = lastResp.next(respText, allowReplace: true);
        if (delta != null && delta.isNotEmpty) {
          if (!emit(UpEvent.text(delta))) return false;
        }
      }
      final rs = data['reasoning'];
      if (rs is String && rs.isNotEmpty) {
        if (!emit(UpEvent.reason(rs))) return false;
      }
      final rsContent = data['reasoning_content'];
      if (rsContent is String && rsContent.isNotEmpty) {
        final delta = lastReason.next(rsContent, allowReplace: true);
        if (delta != null && delta.isNotEmpty) {
          if (!emit(UpEvent.reason(delta))) return false;
        }
      }
    }
    return true;
  });

  // 流消费（后台任务，让上游错误/网络错误都能收尾）。
  // 首事件超时：上游长时间不返回首行（连接挂起/网关卡死）时主动失败，
  // 避免下游无限等待——对应 C++ 的 firstEventTimeoutSec。
  unawaited(() async {
    StreamSubscription<String>? sub;
    var gotFirstLine = false;
    // 统一收尾：cancel 订阅后 onDone 不会触发，必须在此处 complete，
    // 否则调用方的 completer.future 永不完成（请求挂起）。
    void finishUp() {
      if (!completer.isCompleted) completer.complete(r);
    }

    final firstEventTimer = Timer(const Duration(seconds: 120), () {
      if (gotFirstLine || sawDone || aborted) return;
      sub?.cancel();
      if (!sawDone && !aborted && r.error.isEmpty) {
        r.error = '上游 120 秒未返回首事件，连接可能已挂起';
        r.code = -1;
      }
      finishUp();
    });

    try {
      sub = resp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          gotFirstLine = true;
          parser.feedLine(line);
          if (sawDone || aborted) {
            firstEventTimer.cancel();
            sub?.cancel();
            finishUp();
          }
        },
        onError: (Object e) {
          firstEventTimer.cancel();
          if (!sawDone && !aborted && r.error.isEmpty) {
            r.error = '上游流读取失败: $e';
            r.code = -1;
          }
          finishUp();
        },
        onDone: () {
          firstEventTimer.cancel();
          parser.finish();
          finishUp();
        },
      );
    } catch (e) {
      firstEventTimer.cancel();
      if (!sawDone && !aborted && r.error.isEmpty) {
        r.error = '上游流读取失败: $e';
        r.code = -1;
      }
      finishUp();
    }
  }());

  final result = await completer.future;
  if (aborted) {
    result.clientAborted = true;
    return result;
  }
  if (result.error.isNotEmpty) return result;
  if (!sawDone) {
    result.error = "${queued ? '上游排队期间：' : ''}上游提前关闭流，未收到结束事件";
    result.code = -1;
    return result;
  }
  result.ok = true;
  result.model = configName;
  return result;
}

class _NativeTool {
  String id = '';
  String name = '';
  String args = '';
}
