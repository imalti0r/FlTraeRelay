// model_caps.dart - 模型能力描述（对应 C++ Upstream.h 的 ModelCaps）。

class ModelCaps {
  String configName = '';
  String modelName = '';
  String displayName = '';
  int configSource = 1;
  String provider = '';
  bool isPreset = true;
  bool maxMode = false;
  bool ideChatCapable = false;
  String ideFunction = '';
  String maxModelName = ''; // Max 档案模型名（__max 后缀）
  bool present = false;

  int cwDefault = 0;
  List<int> cwMax = [];
  int promptMaxTokens = 0;
  int maxTokens = 0;
  int maxTurn = 0;

  bool supportThinking = false;
  List<String> effortOptions = [];
  List<String> effortOptionsExt = [];
  String effortDefault = '';
  bool vision = true;

  // 计费倍率（display_contact_config）
  double rateBase = 0;
  double rateMember = 0;
  int memberDiscountOff = 0;
  double rateActivity = 0;
  double rateActivityBefore = 0;
  double rateActivityMember = 0;
  String activityType = '';
  List<OffPeakWindow> offPeakWindows = [];
}

class OffPeakWindow {
  int startMinute = 0;
  int endMinute = 0;
  List<int> weekdays = [];
}
