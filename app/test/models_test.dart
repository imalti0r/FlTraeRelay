// 核心算法冒烟测试：genApiKey 格式、RelayConfig JSON 保留、
// 快照增量、tc 解密往返（对称构造 blob）、stop 过滤器。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fltrae_relay/core/crypto_x.dart';
import 'package:fltrae_relay/models.dart';
import 'package:fltrae_relay/core/relay_server.dart';

void main() {
  test('genApiKey 与 C++ crypto::genApiKey 同格式', () {
    final key = RelayConfig.genApiKey();
    expect(key, matches(RegExp(r'^sk-trae-[0-9a-f]{24}$')));
  });

  test('RelayConfig 读写已知字段且保留未知字段', () {
    final cfg = RelayConfig({
      'version': 1,
      'service': {'port': 8317, 'apiKey': 'sk-trae-test', 'keepMe': true},
    });
    expect(cfg.servicePort, 8317);
    expect(cfg.apiKey, 'sk-trae-test');
    cfg.servicePort = 9000;
    cfg.allowAnyApiKey = true;
    expect(cfg.raw['service']['keepMe'], true);
    expect(cfg.raw['service']['port'], 9000);
    expect(cfg.raw['service']['allowAnyApiKey'], true);
    expect(cfg.raw['version'], 1);
  });

  test('models 覆盖项 upsert', () {
    final cfg = RelayConfig(<String, dynamic>{});
    cfg.upsertModelOverride('glm-5.3-flash', {'reasoningEffort': 'high', 'isMaxMode': 1});
    expect(cfg.modelReasoningEffort('glm-5.3-flash'), 'high');
    expect(cfg.modelIsMaxMode('glm-5.3-flash'), 1);
    cfg.upsertModelOverride('glm-5.3-flash', {'reasoningEffort': 'extra_high'});
    expect(cfg.modelReasoningEffort('glm-5.3-flash'), 'extra_high');
    expect(cfg.modelIsMaxMode('glm-5.3-flash'), 1);
  });

  test('SnapshotTracker：累计快照形态', () {
    final t = SnapshotTracker();
    expect(t.next('你好'), '你好');
    expect(t.next('你好世'), '世');
    expect(t.next('你好世界'), '界');
    expect(t.next('你好世界'), null); // 重复帧
  });

  test('SnapshotTracker：增量片段形态（上游实测行为）', () {
    final t = SnapshotTracker();
    // 上游 response / reasoning_content 为纯增量片段，必须逐段发出
    expect(t.next('The', allowReplace: true), 'The');
    expect(t.next(' user', allowReplace: true), ' user');
    expect(t.next(' is', allowReplace: true), ' is');
    expect(t.next(' asking', allowReplace: true), ' asking');
    // 严格模式（allowReplace=false）下变短片段仍按快照规则丢弃
    final strict = SnapshotTracker();
    expect(strict.next('abc'), 'abc');
    expect(strict.next('xy'), null);
  });

  test('StopFilter：扣尾、命中与冲刷', () {
    final f = StopFilter(['END']);
    expect(f.feed('hello '), 'hell'); // 未命中，放出 pend-holdMax 前缀（与 C++ 一致）
    expect(f.feed('wo'), 'o '); // pend='o wo' 放出前缀，扣住 'wo'
    expect(f.feed('rldEND tail'), 'world'); // 命中 END → 放出命中前全部正文
    expect(f.feed('more'), null); // 已命中
  });

  test('AES-CBC 解密往返（自加密 → 解密）', () {
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    final iv = Uint8List.fromList(List.generate(16, (i) => 16 - i));
    const plain = 'The quick brown fox jumps over the lazy dog';
    final cipher = aes128CbcEncryptRaw(key, iv, pkcs7Pad(utf8.encode(plain)));
    final dec = aes128CbcDecrypt(key, iv, cipher);
    expect(dec, isNotNull);
    expect(utf8.decode(dec!), plain);
  });
}
