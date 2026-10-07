#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

/// Window attribute that enables rounded top-level window corners.
/// Redefined for older Windows SDKs; only takes effect on Windows 11.
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_ROUND
#define DWMWCP_ROUND 2
#endif

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    // 不用 CS_HREDRAW|CS_VREDRAW：整窗失效 + 背景刷会在 resize 时产生
    // "擦除→重画"循环闪烁，Flutter 子窗口会自行跟随尺寸变化。
    window_class.style = 0;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    // 背景不交给类刷子：WM_ERASEBKGND 被拦截（防 resize 闪烁），
    // 启动深色底由 Create 后的一次性 FillRect 提供。
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;
  scale_factor_ = scale_factor;

  // 注意：不要切回 Impeller——其 OpenGLES(ANGLE) 后端在"WM_NCCALCSIZE
  // 返回 0"的无边框窗口上完全不合成内容（窗口透明/全黑，DwmExtendFrame、
  // WS_EX_NOREDIRECTIONBITMAP 均无法绕过，Flutter 3.47 引擎限制）。
  // Skia 下 liquid_glass_widgets 走轻量磨砂 shader，玻璃观感略简化但渲染正常。
  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  // 强制重算一次 frame：CreateWindow 期间的 WM_NCCALCSIZE 结果会被系统
  // 后续处理覆盖（原生标题栏残影要等到下一次激活切换才消失），这里显式
  // 触发重算让"客户区=整窗"的无边框布局立即生效。
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);

  // 一次性深色底：窗口显示到 Flutter 首帧之间不闪白。
  // 之后的 WM_ERASEBKGND 一律跳过（见 MessageHandler），避免 resize 时
  // "深色擦除→Flutter 重画"交替闪烁。
  {
    RECT rc;
    GetClientRect(window, &rc);
    HBRUSH bg = CreateSolidBrush(RGB(8, 14, 18));
    FillRect(GetDC(window), &rc, bg);
    DeleteObject(bg);
  }

  // Windows 11 圆角：无边框窗口不会自动获得，显式开启以贴合玻璃风格。
  INT corner_preference = DWMWCP_ROUND;
  DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE,
                        &corner_preference, sizeof(corner_preference));

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_ERASEBKGND:
      // resize/失效时跳过背景擦除：背景刷整窗擦除会与 Flutter 重绘交替
      // 产生闪烁。启动深色底由 Create 后的一次性 FillRect 提供。
      return 1;

    case WM_NCCALCSIZE: {
      // 禁用原生标题栏：客户区覆盖整个窗口（保留 WS_OVERLAPPEDWINDOW 的
      // resize、DWM 阴影与 Aero Snap 能力）。最大化时缩进一圈系统 frame，
      // 避免内容被屏幕边缘裁掉。创建后由 SWP_FRAMECHANGED 触发重算生效。
      if (wparam) {
        if (IsZoomed(hwnd)) {
          const int frame = GetSystemMetrics(SM_CXFRAME) +
                            GetSystemMetrics(SM_CXPADDEDBORDER);
          auto rect = reinterpret_cast<RECT*>(lparam);
          rect->left += frame;
          rect->top += frame;
          rect->right -= frame;
          rect->bottom -= frame;
        }
        return 0;
      }
      break;
    }

    case WM_NCHITTEST: {
      const POINT pt = {static_cast<short>(LOWORD(lparam)),
                        static_cast<short>(HIWORD(lparam))};
      return HitTestFrame(pt);
    }

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

LRESULT Win32Window::HitTestFrame(const POINT& pt) noexcept {
  // 自绘玻璃标题栏的命中测试：边缘给系统缩放手势，顶部条给系统拖动
  // 手势（HTCAPTION 自带拖动、双击最大化与 Aero Snap），右上角按钮区
  // 返回 HTCLIENT 留给 Flutter 处理点击。
  RECT rc;
  if (!GetWindowRect(window_handle_, &rc)) {
    return HTCLIENT;
  }
  const int border = Scale(6, scale_factor_);
  const bool near_left = pt.x < rc.left + border;
  const bool near_right = pt.x >= rc.right - border;
  const bool near_top = pt.y < rc.top + border;
  const bool near_bottom = pt.y >= rc.bottom - border;
  if (near_top && near_left) return HTTOPLEFT;
  if (near_top && near_right) return HTTOPRIGHT;
  if (near_bottom && near_left) return HTBOTTOMLEFT;
  if (near_bottom && near_right) return HTBOTTOMRIGHT;
  if (near_left) return HTLEFT;
  if (near_right) return HTRIGHT;
  if (near_top) return HTTOP;
  if (near_bottom) return HTBOTTOM;

  const int title_bar_height = Scale(48, scale_factor_);
  if (pt.y < rc.top + title_bar_height) {
    // 右上角窗口控制按钮区（最小化/关闭 ≈110 逻辑像素）不抢手势，
    // 交给 Flutter 处理点击。
    const int buttons_zone = Scale(110, scale_factor_);
    if (pt.x < rc.right - buttons_zone) {
      return HTCAPTION;
    }
  }
  return HTCLIENT;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
