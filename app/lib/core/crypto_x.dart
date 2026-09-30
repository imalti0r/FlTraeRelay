// crypto_x.dart - 加密与文本原语：sha512、AES-128-CBC（tc 格式）、UUID、
// 快照增量、UTF-8 安全截断。对应 C++ common/Crypto.cpp 与 Upstream.cpp 的工具函数。

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/export.dart' show AESEngine, KeyParameter, ParametersWithIV;

Uint8List sha512Bytes(List<int> data) =>
    Uint8List.fromList(c.sha512.convert(data).bytes);

String sha512Hex(List<int> data) => c.sha512.convert(data).toString();

/// AES-128-CBC 解密 + PKCS7 去填充。失败返回 null。
Uint8List? aes128CbcDecrypt(Uint8List key, Uint8List iv, Uint8List cipher) {
  if (cipher.isEmpty || cipher.length % 16 != 0) return null;
  try {
    final cbc = CBCBlockCipher(AESEngine())..init(false, ParametersWithIV(KeyParameter(key), iv));
    final padded = Uint8List(cipher.length);
    for (var off = 0; off < cipher.length; off += 16) {
      cbc.processBlock(cipher, off, padded, off);
    }
    return _pkcs7Unpad(padded);
  } catch (_) {
    return null;
  }
}

/// AES-128-CBC 加密（输入须已按 16 字节块对齐，供测试构造 tc 格式密文）。
Uint8List aes128CbcEncryptRaw(Uint8List key, Uint8List iv, Uint8List blocks) {
  assert(blocks.isEmpty || blocks.length % 16 == 0);
  final cbc = CBCBlockCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(blocks.length);
  for (var off = 0; off < blocks.length; off += 16) {
    cbc.processBlock(blocks, off, out, off);
  }
  return out;
}

/// PKCS7 填充。
Uint8List pkcs7Pad(List<int> data) {
  final padLen = 16 - (data.length % 16);
  return Uint8List.fromList([...data, ...List.filled(padLen, padLen)]);
}

Uint8List? _pkcs7Unpad(Uint8List data) {
  if (data.isEmpty) return null;
  final padLen = data.last;
  if (padLen == 0 || padLen > 16 || padLen > data.length) return null;
  for (var i = data.length - padLen; i < data.length; i++) {
    if (data[i] != padLen) return null;
  }
  return Uint8List.sublistView(data, 0, data.length - padLen);
}

final Random _rng = Random.secure();

String genUuid() {
  final b = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    b[i] = _rng.nextInt(256);
  }
  b[6] = (b[6] & 0x0F) | 0x40; // v4
  b[8] = (b[8] & 0x3F) | 0x80;
  final hex = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// 与 C++ crypto::genApiKey 相同格式：sk-trae- + 12 字节 hex。
String genApiKey() {
  const hexChars = '0123456789abcdef';
  final sb = StringBuffer('sk-trae-');
  for (var i = 0; i < 24; i++) {
    sb.write(hexChars[_rng.nextInt(16)]);
  }
  return sb.toString();
}

/// UTF-8 安全截断：不超过 max 字节，且不切在多字节字符中间。
int utf8SafeCut(String s, int max) {
  if (s.length <= max) return s.length;
  // dart 字符串以 UTF-16 存储，逐码单元回退到字符边界
  var end = max;
  while (end > 0 && (s.codeUnitAt(end) & 0xC0) == 0x80 && (s.codeUnitAt(end) & 0xF8) == 0x80) {
    end--;
  }
  // 上面的条件写法等价于"字节属于 UTF-8 续字节"，但 dart 的 codeUnitAt 是
  // UTF-16 单元；对 BMP 外字符（代理对）也要避免拆开。
  if (end > 0 && end < s.length) {
    final cu = s.codeUnitAt(end - 1);
    if (cu >= 0xD800 && cu <= 0xDBFF) end--; // 上一单元是高代理，回退避免拆代理对
  }
  return end < 0 ? 0 : end;
}

/// 正文/思考片段的语义适配器，同时兼容两种上游形态：
/// - **增量片段**（当前实测行为）：新片段不以已累计内容为前缀 → 直接追加并发出；
/// - **累计快照**（旧形态）：新串以已累计内容为前缀且更长 → 只发出多出的部分。
///
/// [allowReplace] 为 true 时按上述规则兼容两种形态（推荐）；
/// 为 false 时严格按快照处理，变短的片段视为无效丢弃。
class SnapshotTracker {
  String _last = '';

  String? next(String chunk, {bool allowReplace = false}) {
    if (chunk.isEmpty) return null;
    // 快照形态：新串是已累计内容的前缀延伸
    if (_last.isNotEmpty && chunk.length > _last.length && chunk.startsWith(_last)) {
      var end = chunk.length;
      // 不把 UTF-16 代理对拆成两半发出
      final prev = chunk.codeUnitAt(end - 1);
      if (prev >= 0xD800 && prev <= 0xDBFF) end--;
      if (end <= _last.length) return null;
      final delta = chunk.substring(_last.length, end);
      _last = chunk.substring(0, end);
      return delta;
    }
    if (_last.isNotEmpty && chunk == _last) return null; // 重复快照帧
    if (!allowReplace && chunk.length < _last.length) return null; // 严格模式：变短丢弃
    // 增量片段（或允许替换的整段）：追加/替换并整段发出
    if (allowReplace) {
      _last = '$_last$chunk';
    } else {
      _last = chunk;
    }
    return chunk;
  }
}
