// model_catalog.dart - 模型目录：get_detail_param（chat_v3 / solo_agent）拉取与解析。
// 对应 C++ src/upstream/ModelCatalog.cpp。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth.dart';
import 'model_caps.dart';
import 'storage.dart' show detectIdeVersion;
import 'upstream.dart';

/// 内部模型过滤（对应 isInternalModelName）。
bool isInternalModelName(String name) {
  final lower = name.toLowerCase();
  if (lower.startsWith('custom_')) return true;
  if (lower.startsWith('search_agent') ||
      lower.startsWith('browser_use') ||
      lower.startsWith('computer_use') ||
      lower.startsWith('file_search') ||
      lower.startsWith('explore_') ||
      (lower.length > 5 && lower.endsWith('-auto'))) {
    return true;
  }
  if (lower == 'doubao-for-auto' ||
      lower == 'glm-4.7' ||
      lower == 'glm-4.6' ||
      lower == 'minimax-m2' ||
      lower == 'minimax-m2.1' ||
      lower == 'kimi-k2-0905') {
    return true;
  }
  for (final suffix in ['summary', 'fast_apply', 'fast_apply_new', 'title_generation', 'input_optimization', 'context_selection']) {
    if (lower == suffix) return true;
  }
  return false;
}

String _jstr(Map<String, dynamic> m, List<String> keys, [String def = '']) {
  for (final k in keys) {
    final v = m[k];
    if (v is String) return v;
    if (v is num) return v.toInt().toString();
  }
  return def;
}

int _jint(Map<String, dynamic> m, List<String> keys, [int def = 0]) {
  for (final k in keys) {
    final v = m[k];
    if (v is num) return v.toInt();
    if (v is String) {
      final p = int.tryParse(v);
      if (p != null) return p;
    }
  }
  return def;
}

bool _jbool(dynamic v, [bool def = false]) => v is bool ? v : def;

String _normalizeEffort(String value) => value.trim().toLowerCase();

void _detectVision(Map<String, dynamic> m, _VisionSignal signal) {
  const boolKeys = [
    'support_vision', 'vision_support', 'vision_enabled', 'support_image',
    'support_image_input', 'image_input_enabled', 'multimodal', 'is_multimodal',
    'support_multimodal', 'vision',
  ];
  for (final k in boolKeys) {
    final v = m[k];
    if (v == null) continue;
    signal.saw = true;
    if (v is bool) {
      signal.vision = signal.vision || v;
    } else if (v is String) {
      final s = v.toLowerCase();
      signal.vision = signal.vision || s == 'true' || s == '1' || s == 'yes';
    }
  }
  const arrKeys = ['capabilities', 'modalities', 'tags', 'features_list'];
  for (final k in arrKeys) {
    final a = m[k];
    if (a is! List) continue;
    for (final item in a) {
      if (item is! String) continue;
      final s = item.toLowerCase();
      if (s.contains('vision') || s.contains('image') || s.contains('multimodal')) {
        signal.saw = true;
        signal.vision = true;
      }
    }
  }
}

class _VisionSignal {
  bool saw = false;
  bool vision = false;
}

/// 计费倍率解析（display_contact_config 为 JSON 字符串）。
void _parseRates(Map<String, dynamic> m, ModelCaps c) {
  final dcc = m['display_contact_config'];
  if (dcc is! String || dcc.isEmpty) return;
  Map<String, dynamic> obj;
  try {
    final decoded = jsonDecode(dcc);
    if (decoded is! Map<String, dynamic>) return;
    obj = decoded;
  } catch (_) {
    return;
  }
  double rateNum(dynamic v) => (v is num && v > 0) ? v.toDouble() : 0;

  final crObj = obj['consumption_rate'];
  if (crObj is Map) {
    final cd = crObj['data'];
    if (cd is Map) {
      final rb = rateNum(cd['rate']);
      if (rb > 0) c.rateBase = rb;
    }
  }
  final dis = obj['discount'];
  if (dis is Map) {
    final dd = dis['data'];
    if (dd is Map) {
      final rm = rateNum(dd['consumption_rate']);
      if (rm > 0) {
        c.rateMember = rm;
        c.memberDiscountOff = (dd['member_discount'] as num?)?.toInt() ?? 0;
      }
    }
  }
  final ad = obj['activity_discount'];
  if (ad is Map) {
    final add = ad['data'];
    if (add is Map) {
      final cur = add['current'];
      if (cur is Map) {
        final r = rateNum(cur['consumption_rate']);
        if (r > 0) {
          c.rateActivity = r;
          final dt = cur['discount_type'];
          if (dt is String && dt.isNotEmpty) c.activityType = dt;
        }
        final b = rateNum(cur['before_consumption_rate']);
        if (b > 0) c.rateActivityBefore = b;
      }
      final mem = add['member'];
      if (mem is Map) {
        final r = rateNum(mem['after_consumption_rate']);
        if (r > 0) c.rateActivityMember = r;
      }
      final op = add['off_peak'];
      if (op is Map) {
        final tw = op['time_windows'];
        if (tw is List) {
          for (final w in tw) {
            if (w is! Map) continue;
            final win = OffPeakWindow()
              ..startMinute = (w['start_minute'] as num?)?.toInt() ?? 0
              ..endMinute = (w['end_minute'] as num?)?.toInt() ?? 0;
            final wd = w['weekdays'];
            if (wd is List) {
              for (final d in wd) {
                if (d is num) win.weekdays.add(d.toInt());
              }
            }
            if (win.endMinute > win.startMinute) c.offPeakWindows.add(win);
          }
        }
      }
    }
  }
}

void _capsFromModelJson(Map<String, dynamic> m, ModelCaps c) {
  c.configName = _jstr(m, ['config_name', 'name', 'configName'], c.configName);
  c.modelName = _jstr(m, ['model_name', 'modelName', 'raw_model_name'], c.modelName.isEmpty ? c.configName : c.modelName);
  c.displayName = _jstr(m, ['display_model_name', 'display_name', 'displayName'],
      c.displayName.isEmpty ? c.configName : c.displayName);
  c.configSource = _jint(m, ['config_source', 'configSource'], c.configSource);
  c.provider = _jstr(m, ['provider'], c.provider);
  final preset = m['is_preset'];
  c.isPreset = preset is bool ? preset : true;
  final mm = m['max_mode'];
  if (mm is bool) c.maxMode = mm;
  final dm = m['is_dollar_max'];
  if (dm is bool && dm) c.maxMode = true;
  final dc = m['display_config'];
  if (dc is Map) {
    final dmm = dc['max_mode'];
    if (dmm is bool && dmm) c.maxMode = true;
    final dn = dc['display_name'];
    if (dn is String && (c.displayName.isEmpty || c.displayName == c.configName)) {
      c.displayName = dn;
    }
  }
  _parseRates(m, c);

  final cws = m['context_window_size'];
  if (cws is Map) {
    c.cwDefault = _jint(cws.map((k, v) => MapEntry(k.toString(), v)), ['default'], c.cwDefault);
    final mx = cws['max'];
    if (mx is List) {
      c.cwMax = [for (final v in mx) (v as num).toInt()];
    } else if (mx is num) {
      c.cwMax = [mx.toInt()];
    }
  }
  final tokens = m['context_window_tokens'];
  if (tokens is Map) {
    final dev = _jint(tokens.map((k, v) => MapEntry(k.toString(), v)), ['dev'], 0);
    if (dev > 0) c.cwDefault = dev;
    final mx = _jint(tokens.map((k, v) => MapEntry(k.toString(), v)), ['max'], 0);
    if (mx > 0 && c.cwMax.isEmpty) c.cwMax = [mx];
  }
  c.promptMaxTokens = _jint(m, ['prompt_max_tokens'], c.promptMaxTokens);
  c.maxTokens = _jint(m, ['max_tokens'], c.maxTokens);
  c.maxTurn = _jint(m, ['max_turn'], c.maxTurn);

  // features 可能是 JSON 字符串
  Map<String, dynamic>? featObj;
  final feat = m['features'];
  if (feat is String && feat.isNotEmpty) {
    try {
      final d = jsonDecode(feat);
      if (d is Map<String, dynamic>) featObj = d;
    } catch (_) {}
  } else if (feat is Map<String, dynamic>) {
    featObj = feat;
  }
  if (featObj != null) {
    final fcw = featObj['context_windows'];
    if (fcw is Map) {
      final fd = fcw['data'];
      if (fd is Map) {
        c.cwDefault = _jint(fd.map((k, v) => MapEntry(k.toString(), v)), ['dev_context'], c.cwDefault);
        if (c.cwMax.isEmpty) {
          final mc = _jint(fd.map((k, v) => MapEntry(k.toString(), v)), ['max_context'], 0);
          if (mc > 0) c.cwMax = [mc];
        }
        final mcl = fd['max_context_list'];
        if (mcl is List && mcl.isNotEmpty) {
          c.cwMax = [for (final v in mcl) (v as num).toInt()];
        }
        c.maxTurn = _jint(fd.map((k, v) => MapEntry(k.toString(), v)), ['max_turns'], c.maxTurn);
      }
    }
  }

  // R5 思考档位
  final rec = m['reasoning_effort_config'];
  if (rec is Map) {
    final support = rec['support_thinking'];
    final opts = rec['options'];
    if (support == true && opts is List && opts.isNotEmpty) {
      var bad = false;
      final parsed = <String>[];
      for (final o in opts) {
        if (o is! String) {
          bad = true;
          break;
        }
        final v = _normalizeEffort(o);
        if (v.isEmpty || parsed.contains(v)) {
          bad = true;
          break;
        }
        parsed.add(v);
      }
      if (!bad && parsed.isNotEmpty) {
        var defv = '';
        final dl = rec['default_level'];
        if (dl is String) defv = _normalizeEffort(dl);
        c.supportThinking = true;
        c.effortOptions = parsed;
        c.effortDefault = parsed.contains(defv) ? defv : parsed.first;
      }
    }
  }
  final reo = m['reasoning_effort_options'];
  if (reo is List) {
    for (final item in reo) {
      if (item is! String) continue;
      final lv = _normalizeEffort(item);
      if (lv.isNotEmpty && !c.effortOptionsExt.contains(lv)) c.effortOptionsExt.add(lv);
    }
    if (c.effortOptionsExt.isNotEmpty) {
      final de = m['default_reasoning_effort'];
      if (de is String && de.isNotEmpty) c.effortDefault = de;
      c.supportThinking = true;
    }
  }

  // 视觉能力
  final signal = _VisionSignal();
  _detectVision(m, signal);
  if (featObj != null) _detectVision(featObj, signal);
  c.vision = signal.saw ? signal.vision : true;
  c.present = true;
}

void _mergeCaps(ModelCaps dst, ModelCaps src) {
  if (dst.modelName.isEmpty) dst.modelName = src.modelName;
  if (dst.displayName.isEmpty) dst.displayName = src.displayName;
  if (dst.provider.isEmpty) dst.provider = src.provider;
  if (dst.configSource == 0) dst.configSource = src.configSource;
  dst.maxMode = dst.maxMode || src.maxMode;
  dst.ideChatCapable = dst.ideChatCapable || src.ideChatCapable;
  if (dst.ideFunction.isEmpty && src.ideFunction.isNotEmpty) dst.ideFunction = src.ideFunction;
  if (src.ideChatCapable && src.modelName.contains('__dev')) dst.modelName = src.modelName;
  if (dst.maxModelName.isEmpty && src.maxModelName.isNotEmpty) dst.maxModelName = src.maxModelName;
  dst.present = dst.present || src.present;
  if (src.cwDefault > dst.cwDefault) dst.cwDefault = src.cwDefault;
  for (final v in src.cwMax) {
    if (!dst.cwMax.contains(v)) dst.cwMax.add(v);
  }
  if (src.promptMaxTokens > dst.promptMaxTokens) dst.promptMaxTokens = src.promptMaxTokens;
  if (src.maxTokens > dst.maxTokens) dst.maxTokens = src.maxTokens;
  if (src.maxTurn > dst.maxTurn) dst.maxTurn = src.maxTurn;
  dst.supportThinking = dst.supportThinking || src.supportThinking;
  dst.vision = dst.vision || src.vision;
  for (final v in src.effortOptions) {
    if (!dst.effortOptions.contains(v)) dst.effortOptions.add(v);
  }
  for (final v in src.effortOptionsExt) {
    if (!dst.effortOptionsExt.contains(v)) dst.effortOptionsExt.add(v);
  }
  if (dst.effortDefault.isEmpty && src.effortDefault.isNotEmpty) dst.effortDefault = src.effortDefault;
  if (dst.rateBase == 0 && src.rateBase > 0) dst.rateBase = src.rateBase;
  if (dst.rateMember == 0 && src.rateMember > 0) dst.rateMember = src.rateMember;
  if (dst.memberDiscountOff == 0 && src.memberDiscountOff > 0) dst.memberDiscountOff = src.memberDiscountOff;
  if (dst.rateActivity == 0 && src.rateActivity > 0) dst.rateActivity = src.rateActivity;
  if (dst.rateActivityBefore == 0 && src.rateActivityBefore > 0) dst.rateActivityBefore = src.rateActivityBefore;
  if (dst.rateActivityMember == 0 && src.rateActivityMember > 0) dst.rateActivityMember = src.rateActivityMember;
  if (dst.activityType.isEmpty && src.activityType.isNotEmpty) dst.activityType = src.activityType;
  if (dst.offPeakWindows.isEmpty && src.offPeakWindows.isNotEmpty) dst.offPeakWindows = src.offPeakWindows;
}

/// 模型目录缓存：启动拉取、成功后每小时刷新、失败每 5 分钟重试。
class ModelCatalog {
  final List<ModelCaps> _cache = [];
  String _cacheErr = '';
  bool _attempted = false;
  final List<String> _trace = [];
  List<String> get trace => List.unmodifiable(_trace);
  Timer? _timer;
  final http.Client _client = http.Client();
  AccountProvider? _pool;

  /// 由外部注入账号池（避免循环依赖）。
  void bind(AccountProvider pool) => _pool = pool;

  List<ModelCaps> get cached => List.unmodifiable(_cache);
  String get cacheError => _cacheErr;

  /// 阻塞直到首次尝试完成（对应 all() 的 m_attempted 等待）。
  Future<void> waitFirstAttempt() async {
    while (!_attempted) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// 按config_name 精确匹配，display_name 模糊兜底。
  ModelCaps? get(String configName) {
    for (final c in _cache) {
      if (c.configName.toLowerCase() == configName.toLowerCase()) return c;
    }
    for (final c in _cache) {
      if (c.displayName.toLowerCase().contains(configName.toLowerCase())) {
        return c;
      }
    }
    return null;
  }

  void start() {
    _tick();
  }

  void _tick() {
    _timer?.cancel();
    _refresh().then((ok) {
      _timer = Timer(ok ? const Duration(hours: 1) : const Duration(minutes: 5), _tick);
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _client.close();
  }

  Future<bool> _refresh() async {
    final pool = _pool;
    if (pool == null || pool.accounts.isEmpty) {
      _cacheErr = '未发现可用账号';
      _attempted = true;
      return false;
    }
    final acc = pool.accounts.first;
    await pool.ensureFreshToken(acc);
    // 上游目录接口存在内容波动（同一请求偶发只返回少数条目），
    // 单次刷新内置快速重试，拿到完整目录或重试耗尽为止。
    var ok = false;
    for (var attempt = 0; attempt < 4 && !ok; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      ok = await refreshOnce(acc);
    }
    _attempted = true;
    return ok;
  }

  /// 拉取 chat_v3 + solo_agent 目录并合并。
  Future<bool> refreshOnce(Account acc) async {
    final version = detectIdeVersion();
    // 版本头为空时上游会返回裁剪目录，必须带兜底值（与 C++ 行为一致）
    final ver = (version?.$1 ?? '').isEmpty ? '3.3.102' : version!.$1;
    final code = (version?.$2 ?? '').isEmpty ? '20260916' : version!.$2;
    final merged = <ModelCaps>[];
    final primaryVisibleNames = <String>[];
    var primaryCatalogOk = false;
    var allOk = true;
    var err = '';

    Future<void> loadDetailCatalog(String functionName) async {
      final body = jsonEncode({
        'function': functionName,
        'config_names': null,
        'need_prompt': false,
        'current_config_info': null,
        'poly_prompt': true,
        'mode_type': null,
        'agent_type': null,
      });
      try {
        final resp = await _client
            .post(
              Uri.parse('https://trae-api-cn.mchost.guru/api/ide/v1/get_detail_param'),
              headers: ideHeaders(acc, ver, code),
              body: body,
            )
            .timeout(const Duration(seconds: 30));
        if (resp.statusCode != 200) {
          allOk = false;
          err = '$functionName HTTP ${resp.statusCode}';
          return;
        }
        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is! Map) {
          allOk = false;
          err = '$functionName 响应不是合法 JSON';
          return;
        }
        final data = decoded['data'];
        final root = (data is Map) ? data : decoded;
        final cil = root['config_info_list'];
        if (cil is! List) {
          allOk = false;
          err = '$functionName 响应缺少模型列表';
          return;
        }
        final primary = functionName.toLowerCase() == 'chat_v3' || functionName.toLowerCase() == 'solo_agent';
        if (primary) primaryCatalogOk = true;
        void trace(String m) => _trace.add('[$functionName] $m');
        trace('config_info_list: ${cil.length}');
        for (final cfgItem in cil) {
          if (cfgItem is! Map) continue;
          final item = cfgItem.map((k, v) => MapEntry(k.toString(), v));
          final cfgName = _jstr(item, ['config_name']);
          final hidden = _jbool(item['is_invisible_to_user']) || !_jbool(item['config_switch'], true);
          var parentMax = _jbool(item['max_mode']);
          var custom = false;
          final parentDisplay = item['display_config'];
          if (parentDisplay is Map) {
            custom = _jbool(parentDisplay['is_custom_model']);
            parentMax = parentMax || _jbool(parentDisplay['max_mode']);
          }
          if (hidden || custom || cfgName.isEmpty) continue;
          final detailSource = _jint(item, ['config_source', 'configSource'], 1);
          if (primary && detailSource == 1 && !isInternalModelName(cfgName)) {
            final dup = primaryVisibleNames.any((v) => v.toLowerCase() == cfgName.toLowerCase());
            if (!dup) primaryVisibleNames.add(cfgName);
          }
          final mdl = item['model_detail_list'];
          if (mdl is! List) continue;
          for (final mdRaw in mdl) {
            if (mdRaw is! Map) continue;
            final md = mdRaw.map((k, v) => MapEntry(k.toString(), v));
            final c = ModelCaps();
            _capsFromModelJson(item, c); // 公共能力在 config 条目
            c.configName = cfgName;
            _capsFromModelJson(md, c); // 档位参数在 detail 条目
            c.configName = cfgName;
            c.ideChatCapable = true;
            final rawFn = _jstr(md, ['raw_chat_function', 'rawChatFunction']);
            c.ideFunction = rawFn.isEmpty ? functionName : rawFn;
            if (isInternalModelName(c.configName) || c.configSource != 1) continue;
            if (parentMax) c.maxMode = true;
            final detailModelName = _jstr(md, ['model_name', 'modelName']);
            var isMaxDetail = _jbool(md['max_mode']);
            if (!isMaxDetail && detailModelName.length >= 5 &&
                detailModelName.endsWith('__max')) {
              isMaxDetail = true;
            }
            if (isMaxDetail && detailModelName.isNotEmpty) c.maxModelName = detailModelName;
            if (!md.containsKey('config_source') && item.containsKey('config_source')) {
              final cs = item['config_source'];
              if (cs is num) c.configSource = cs.toInt();
            }
            if (c.configSource != 1) continue;
            final existing = merged.indexWhere((e) => e.configName.toLowerCase() == c.configName.toLowerCase());
            if (existing < 0) {
              merged.add(c);
            } else {
              _mergeCaps(merged[existing], c);
            }
          }
        }
      } catch (e) {
        allOk = false;
        err = '$functionName $e';
      }
    }

    await loadDetailCatalog('chat_v3');
    await loadDetailCatalog('solo_agent');
    if (!allOk) {
      _cacheErr = err;
      return false;
    }
    if (primaryCatalogOk && primaryVisibleNames.isNotEmpty) {
      merged.retainWhere((c) => primaryVisibleNames
          .any((v) => v.toLowerCase() == c.configName.toLowerCase()));
    }
    if (merged.isEmpty) {
      _cacheErr = '模型表为空（账号未登录或上游不可达）';
      return false;
    }
    _cache
      ..clear()
      ..addAll(merged);
    _cacheErr = '';
    return true;
  }
}

/// AccountProvider 由 AccountPool 实现并注入 ModelCatalog。
abstract class AccountProvider {
  List<Account> get accounts;
  Future<bool> ensureFreshToken(Account acc);
}
