// tray_icon.h - 托盘图标与"关闭最小化"行为的原生层管理。
// 与 Dart 侧通过 MethodChannel('fltrae_relay/tray') 通信：
//   Dart → 原生: setEnabled(bool)      开关"关闭时最小化到托盘"
//   原生 → Dart: onRestore             用户双击/菜单"显示"恢复窗口时通知
//   原生 → Dart: onExitRequest         用户点了托盘菜单"退出"
#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>
#include <shellapi.h>

#include <functional>

class TrayIcon {
 public:
  // callback 在托盘交互触发时调用（必须在 FlutterMessenger 有效期内存活）
  void Initialize(HWND window,
                  std::function<void()> on_restore,
                  std::function<void()> on_exit_request);
  void Dispose();

  // "关闭时最小化到托盘"开关：true 时拦截 WM_CLOSE 隐藏到托盘
  void set_close_to_tray(bool enabled) { close_to_tray_ = enabled; }
  bool close_to_tray() const { return close_to_tray_; }

  // 返回该消息是否已被托盘处理（处理过的返回 true，调用方直接返回 0）
  bool HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  // 供 WM_CLOSE 拦截：隐藏窗口到托盘
  void HideToTray(HWND hwnd);

 private:
  void CreateTrayIcon();
  void RemoveTrayIcon();

  HWND window_ = nullptr;
  NOTIFYICONDATA nid_ = {};
  bool tray_added_ = false;
  bool close_to_tray_ = false;
  std::function<void()> on_restore_;
  std::function<void()> on_exit_request_;

  static constexpr UINT WM_APP_TRAY = WM_APP + 1;
  static constexpr UINT TRAY_ICON_ID = 1;
};

#endif  // RUNNER_TRAY_ICON_H_
