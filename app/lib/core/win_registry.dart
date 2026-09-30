// win_registry.dart - Windows 注册表读取的最小 FFI 绑定。
// 仅覆盖探测 Trae 安装目录所需的 Uninstall 键枚举（对应 C++ Storage.cpp 的 scanUninstall）。

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final _advapi32 = DynamicLibrary.open('advapi32.dll');

typedef _RegOpenKeyExWN = Int32 Function(
    Uint32 hkey, Pointer<Utf16> subKey, Uint32 options, Uint32 sam, Pointer<UintPtr> result);
typedef _RegOpenKeyExWD = int Function(
    int hkey, Pointer<Utf16> subKey, int options, int sam, Pointer<UintPtr> result);
final _regOpenKeyExW = _advapi32.lookupFunction<_RegOpenKeyExWN, _RegOpenKeyExWD>('RegOpenKeyExW');

typedef _RegEnumKeyExWN = Int32 Function(
    Uint32 hkey, Uint32 index, Pointer<Utf16> name, Pointer<Uint32> nameLen);
typedef _RegEnumKeyExWD = int Function(
    int hkey, int index, Pointer<Utf16> name, Pointer<Uint32> nameLen);
final _regEnumKeyExW = _advapi32.lookupFunction<_RegEnumKeyExWN, _RegEnumKeyExWD>('RegEnumKeyExW');

typedef _RegQueryValueExWN = Int32 Function(Uint32 hkey, Pointer<Utf16> valueName,
    Pointer<Uint32> reserved, Pointer<Uint32> type, Pointer<Uint8> data, Pointer<Uint32> dataLen);
typedef _RegQueryValueExWD = int Function(int hkey, Pointer<Utf16> valueName,
    Pointer<Uint32> reserved, Pointer<Uint32> type, Pointer<Uint8> data, Pointer<Uint32> dataLen);
final _regQueryValueExW =
    _advapi32.lookupFunction<_RegQueryValueExWN, _RegQueryValueExWD>('RegQueryValueExW');

typedef _RegCloseKeyN = Int32 Function(Uint32 hkey);
typedef _RegCloseKeyD = int Function(int hkey);
final _regCloseKey = _advapi32.lookupFunction<_RegCloseKeyN, _RegCloseKeyD>('RegCloseKey');

const int _hkeyCurrentUser = 0x80000001;
const int _hkeyLocalMachine = 0x80000002;
const int _keyRead = 0x20019;
const int _keyWow6432Key = 0x0200;
const int _errorSuccess = 0;
const int _regSz = 1;
const int _regExpandSz = 2;

/// 展开 REG_EXPAND_SZ 中的 %VAR% 引用。
String _expandEnv(String s) => s.replaceAllMapped(RegExp(r'%([^%]+)%'), (m) {
      final v = Platform.environment[m.group(1)];
      return (v == null || v.isEmpty) ? m.group(0)! : v;
    });

/// 枚举 Uninstall 键，返回 DisplayName 含 [nameContains] 且不含排除项的
/// 第一个 InstallLocation（已去除尾部斜杠并展开环境变量）。找不到返回 null。
String? findUninstallLocation({
  required bool currentUser,
  required bool wow32,
  required String nameContains,
  required List<String> excludeContains,
}) {
  final root = currentUser ? _hkeyCurrentUser : _hkeyLocalMachine;
  final sam = wow32 ? _keyWow6432Key : 0;
  final subKey = r'Software\Microsoft\Windows\CurrentVersion\Uninstall'.toNativeUtf16();
  final base = calloc<UintPtr>();
  var rc = _regOpenKeyExW(root, subKey, 0, _keyRead | sam, base);
  calloc.free(subKey);
  if (rc != _errorSuccess) {
    calloc.free(base);
    return null;
  }
  final hkey = base.value;
  calloc.free(base);

  String? found;
  final nameBuf = calloc<Uint16>(512);
  final nameLen = calloc<Uint32>();
  final typeBuf = calloc<Uint32>();
  final dataBuf = calloc<Uint8>(8192);
  final dataLen = calloc<Uint32>();

  for (var idx = 0;; idx++) {
    nameLen.value = 512;
    rc = _regEnumKeyExW(hkey, idx, nameBuf.cast(), nameLen);
    if (rc != _errorSuccess) break;
    final sub = String.fromCharCodes(nameBuf.asTypedList(nameLen.value));
    final subName = sub.toNativeUtf16();
    final child = calloc<UintPtr>();
    rc = _regOpenKeyExW(hkey, subName, 0, _keyRead | sam, child);
    calloc.free(subName);
    if (rc != _errorSuccess) {
      calloc.free(child);
      continue;
    }
    final keyHandle = child.value;
    calloc.free(child);

    final displayName = _readSz(keyHandle, 'DisplayName', typeBuf, dataBuf, dataLen);
    final location = _readSz(keyHandle, 'InstallLocation', typeBuf, dataBuf, dataLen);
    _regCloseKey(keyHandle);

    final lower = displayName.toLowerCase();
    var excluded = false;
    for (final e in excludeContains) {
      if (lower.contains(e)) excluded = true;
    }
    if (lower.contains(nameContains) && !excluded && location.isNotEmpty) {
      var loc = _expandEnv(location);
      while (loc.endsWith('\\') || loc.endsWith('/')) {
        loc = loc.substring(0, loc.length - 1);
      }
      if (loc.isNotEmpty) {
        found = loc;
        break;
      }
    }
  }

  calloc.free(nameBuf);
  calloc.free(nameLen);
  calloc.free(typeBuf);
  calloc.free(dataBuf);
  calloc.free(dataLen);
  _regCloseKey(hkey);
  return found;
}

String _readSz(int key, String valueName, Pointer<Uint32> typeBuf, Pointer<Uint8> dataBuf,
    Pointer<Uint32> dataLen) {
  final vn = valueName.toNativeUtf16();
  dataLen.value = 8192;
  final rc = _regQueryValueExW(key, vn, nullptr, typeBuf, dataBuf, dataLen);
  calloc.free(vn);
  if (rc != _errorSuccess) return '';
  final type = typeBuf.value;
  if (type != _regSz && type != _regExpandSz) return '';
  final bytes = dataBuf.asTypedList(dataLen.value);
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final u = bytes[i] | (bytes[i + 1] << 8);
    if (u == 0) break;
    units.add(u);
  }
  final s = String.fromCharCodes(units);
  return type == _regExpandSz ? _expandEnv(s) : s;
}
