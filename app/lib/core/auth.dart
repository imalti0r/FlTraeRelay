// auth.dart - 账号与凭据数据模型（对应 C++ accounts/Storage.h 的 AuthData/Account）。

class AuthData {
  String accessToken = '';
  String refreshToken = '';
  String userId = '';
  String expiredRaw = '';
  int expiredTs = 0; // 秒级时间戳，0 = 未知
  String host = '';
  String clientId = '';
  // providerSpecificData / commonParams 中的身份字段
  final Map<String, String> psd = {};
  Map<String, dynamic> raw = {};

  bool get empty => accessToken.isEmpty;

  String? psdValue(List<String> keys) {
    for (final k in keys) {
      final v = psd[k];
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }
}

class TraeEdition {
  const TraeEdition({required this.id, required this.userDir, required this.label});
  final String id; // cn | solo | work | sg | solo-sg
  final String userDir; // %APPDATA%\<dist>\User
  final String label;
}

class Account {
  AuthData auth = AuthData();
  String machineId = '';
  String deviceId = '';
  String editionId = '';
  String nickname = '';

  // 运行时状态
  double credits = -1; // -1 = 未知
  int payIdentity = 0; // 0=Free, >0=会员（-1 未知）
  int active = 0; // 当前并发数
  int lastUsedTs = 0;
  int lastRequestTsMs = 0;
  bool creditsFresh = false;

  // 到期时间（秒级，0=未知）——调度"到期优先"按它排序
  int get expiredTs => auth.expiredTs;

  /// 唯一标识：发行版 + userId（同名账号去重用）。
  String get id => '$editionId:${auth.userId}';
}
