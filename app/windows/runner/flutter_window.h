#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "tray_icon.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 托盘图标与"关闭最小化到托盘"行为。
  TrayIcon tray_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;

  // 窗口控制（最小化/最大化切换/关闭），配合自绘玻璃标题栏。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;

  // 子类化 FlutterView 的窗口过程：无边框后整窗都是 Flutter 客户区，
  // 标题栏拖动区/边缘缩放区的 WM_NCHITTEST 在这里以 HTTRANSPARENT
  // 穿透给顶层窗口，走系统拖动与缩放手势。
  static LRESULT CALLBACK ViewWndProc(HWND window, UINT message,
                                      WPARAM wparam, LPARAM lparam) noexcept;

  // FlutterView 原始窗口过程（子类化前保存，用于转发其余消息）。
  static WNDPROC original_view_wndproc_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
