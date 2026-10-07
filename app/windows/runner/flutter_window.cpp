#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

WNDPROC FlutterWindow::original_view_wndproc_ = nullptr;

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

  // 托盘：与 Dart 侧建立 MethodChannel；"关闭时最小化到托盘"由 Dart 推送开关。
  auto messenger = flutter_controller_->engine()->messenger();
  // 托盘"退出"：RequestExit 置 force_exit_ 后发 WM_CLOSE，
  // WM_CLOSE 处理器放行 → DefWindowProc → DestroyWindow → 退出。
  tray_.Initialize(
      GetHandle(),
      []() {},
      [this]() { tray_.RequestExit(); });
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
        } else if (call.method_name() == "exitApp") {
          // 与托盘菜单"退出"同一条路径：force_exit_ + WM_CLOSE 放行退出
          tray_.RequestExit();
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
  // channel 生命周期由 tray_channel_ 持有
  tray_channel_ = std::move(channel);

  // 自绘玻璃标题栏的窗口控制：最小化 / 最大化切换 / 关闭。
  auto window_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "fltrae_relay/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "minimize") {
          ShowWindow(GetHandle(), SW_MINIMIZE);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "toggleMaximize") {
          if (IsZoomed(GetHandle())) {
            ShowWindow(GetHandle(), SW_RESTORE);
          } else {
            ShowWindow(GetHandle(), SW_MAXIMIZE);
          }
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "close") {
          // 走 WM_CLOSE 以复用"关闭时最小化到托盘"的拦截逻辑。
          PostMessage(GetHandle(), WM_CLOSE, 0, 0);
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
  window_channel_ = std::move(window_channel);

  // 子类化 FlutterView：无边框后整窗都是 Flutter 客户区，父窗口收不到
  // 标题栏/边缘区的 WM_NCHITTEST。子窗口对命中拖动/缩放区的鼠标返回
  // HTTRANSPARENT，让消息穿透到顶层窗口走系统拖动与缩放手势。
  HWND view_hwnd = flutter_controller_->view()->GetNativeWindow();
  SetPropW(view_hwnd, L"FlTraeRelayWindow", reinterpret_cast<HANDLE>(this));
  original_view_wndproc_ = reinterpret_cast<WNDPROC>(
      SetWindowLongPtr(view_hwnd, GWLP_WNDPROC,
                       reinterpret_cast<LONG_PTR>(&FlutterWindow::ViewWndProc)));

  // 直接显示窗口：引擎在窗口可见后才持续合成，"等首帧再显示"会死锁。
  // 窗口底色由 Create 后的一次性 FillRect 提供（深色，不闪白）。
  // 注意：不要定时重试 ForceRedraw——反复请求会不断重置 Impeller 的
  // 合成管线，反而让首帧永远画不出来（窗口透明）。
  ShowWindow(GetHandle(), SW_SHOW);
  flutter_controller_->ForceRedraw();

  return true;
}

LRESULT CALLBACK FlutterWindow::ViewWndProc(HWND window, UINT message,
                                            WPARAM wparam,
                                            LPARAM lparam) noexcept {
  if (message == WM_NCHITTEST) {
    auto self = reinterpret_cast<FlutterWindow*>(
        GetPropW(window, L"FlTraeRelayWindow"));
    if (self) {
      const POINT pt = {static_cast<short>(LOWORD(lparam)),
                        static_cast<short>(HIWORD(lparam))};
      if (self->HitTestFrame(pt) != HTCLIENT) {
        // 标题栏拖动区或边缘缩放区：穿透给顶层窗口处理。
        return HTTRANSPARENT;
      }
    }
  }
  return CallWindowProc(original_view_wndproc_, window, message, wparam,
                        lparam);
}

void FlutterWindow::OnDestroy() {
  tray_.Dispose();
  if (flutter_controller_) {
    // 还原 FlutterView 的窗口过程与属性（窗口即将销毁，仅保持整洁）。
    HWND view_hwnd = flutter_controller_->view()->GetNativeWindow();
    if (original_view_wndproc_) {
      SetWindowLongPtr(view_hwnd, GWLP_WNDPROC,
                       reinterpret_cast<LONG_PTR>(original_view_wndproc_));
      original_view_wndproc_ = nullptr;
    }
    RemovePropW(view_hwnd, L"FlTraeRelayWindow");
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 非客户区定制（去标题栏/自算命中测试）必须由基类处理：
  // 引擎与插件的顶层消息分发不感知 WM_NCCALCSIZE/WM_NCHITTEST 定制。
  const bool is_nc_customization =
      message == WM_NCCALCSIZE || message == WM_NCHITTEST;

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_ && !is_nc_customization) {
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
      // （内嵌 HTTP 服务不中断）。托盘"退出"发起的关闭（force_exit_）放行。
      if (tray_.ShouldHideOnClose(hwnd)) {
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
