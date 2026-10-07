#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // 必须禁用 Impeller 切回 Skia：Impeller 的 OpenGLES(ANGLE) 后端在
  // "WM_NCCALCSIZE 返回 0"的无边框窗口上完全不合成内容（窗口透明/全黑），
  // DwmExtendFrameIntoClientArea、WS_EX_NOREDIRECTIONBITMAP 均无法绕过，
  // 属 Flutter 3.47 引擎限制。Skia 下玻璃走 liquid_glass_widgets 的
  // 轻量磨砂 shader，观感略简化但渲染稳定。
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // 默认方形窗口：宽度 = 屏幕物理宽度的 1/2，高宽比 1:1。
  // Create 内部会按显示器 DPI 把逻辑值放大为物理值，这里先换回逻辑值。
  const POINT anchor = {10, 10};
  UINT dpi = FlutterDesktopGetDpiForMonitor(
      MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST));
  double scale_factor = dpi / 96.0;
  const int physical_width = GetSystemMetrics(SM_CXSCREEN) / 2;
  const int physical_height = physical_width;
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(
      static_cast<unsigned int>(physical_width / scale_factor),
      static_cast<unsigned int>(physical_height / scale_factor));
  if (!window.Create(L"fltrae_relay", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
