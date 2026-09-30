#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // 托盘：与 Dart 侧建立 MethodChannel；"关闭时最小化到托盘"由 Dart 推送开关。
  auto messenger = flutter_controller_->engine()->messenger();
  tray_.Initialize(GetHandle(), [this]() {}, []() {});
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "fltrae_relay/tray",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "setEnabled") {
          bool enabled = false;
          const auto* args = std::get_if<bool>(call.arguments());
          if (args) enabled = *args;
          tray_.set_close_to_tray(enabled);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "hideToTray") {
          tray_.HideToTray(GetHandle());
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
  // channel 生命周期由 tray_channel_ 持有
  tray_channel_ = std::move(channel);

  return true;
}

void FlutterWindow::OnDestroy() {
  tray_.Dispose();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (tray_.HandleMessage(hwnd, message, wparam, lparam)) {
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_CLOSE:
      // "关闭时最小化到托盘"开启时：拦截关闭，隐藏到托盘继续运行
      // （内嵌 HTTP 服务不中断）。
      if (tray_.close_to_tray()) {
        tray_.HideToTray(hwnd);
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
