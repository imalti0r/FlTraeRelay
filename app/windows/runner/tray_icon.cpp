// tray_icon.cpp - Shell_NotifyIcon 托盘实现：图标、气泡、左键恢复、右键菜单。
#include "tray_icon.h"

#include <string>

namespace {
// 托盘菜单命令
constexpr int IDM_RESTORE = 1001;
constexpr int IDM_EXIT = 1002;

HICON LoadAppSmallIcon(HWND window) {
  // 与 Runner.rc 的 IDI_APP_ICON 一致；取小图标尺寸适配托盘
  HICON icon = static_cast<HICON>(LoadImage(GetModuleHandle(nullptr),
                                            MAKEINTRESOURCE(101), IMAGE_ICON,
                                            GetSystemMetrics(SM_CXSMICON),
                                            GetSystemMetrics(SM_CYSMICON),
                                            LR_DEFAULTCOLOR));
  if (!icon) {
    icon = static_cast<HICON>(LoadImage(GetModuleHandle(nullptr),
                                        MAKEINTRESOURCE(101), IMAGE_ICON, 0, 0,
                                        LR_DEFAULTCOLOR));
  }
  if (!icon) {
    icon = LoadIcon(nullptr, IDI_APPLICATION);
  }
  return icon;
}
}  // namespace

void TrayIcon::Initialize(HWND window,
                          std::function<void()> on_restore,
                          std::function<void()> on_exit_request) {
  window_ = window;
  on_restore_ = std::move(on_restore);
  on_exit_request_ = std::move(on_exit_request);
}

void TrayIcon::Dispose() {
  RemoveTrayIcon();
}

void TrayIcon::CreateTrayIcon() {
  if (tray_added_) return;
  ZeroMemory(&nid_, sizeof(nid_));
  nid_.cbSize = sizeof(NOTIFYICONDATA);
  nid_.hWnd = window_;
  nid_.uID = TRAY_ICON_ID;
  nid_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid_.uCallbackMessage = WM_APP_TRAY;
  nid_.hIcon = LoadAppSmallIcon(window_);
  lstrcpyn(nid_.szTip, L"FlTraeRelay", ARRAYSIZE(nid_.szTip));
  tray_added_ = Shell_NotifyIcon(NIM_ADD, &nid_) != FALSE;
}

void TrayIcon::RemoveTrayIcon() {
  if (!tray_added_) return;
  Shell_NotifyIcon(NIM_DELETE, &nid_);
  tray_added_ = false;
}

void TrayIcon::HideToTray(HWND hwnd) {
  CreateTrayIcon();
  ShowWindow(hwnd, SW_HIDE);
}

void TrayIcon::RequestExit() {
  force_exit_ = true;
  PostMessage(window_, WM_CLOSE, 0, 0);
}

bool TrayIcon::ShouldHideOnClose(HWND hwnd) {
  if (force_exit_) {
    return false;  // 托盘"退出"发起的关闭：放行，走默认 DestroyWindow
  }
  if (close_to_tray_) {
    HideToTray(hwnd);
    return true;  // 已拦截隐藏
  }
  return false;   // 开关未开：放行正常关闭
}

bool TrayIcon::HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                             LPARAM lparam) {
  if (message == WM_APP_TRAY && wparam == TRAY_ICON_ID) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONDBLCLK:
      case WM_LBUTTONUP:
        // 左键恢复窗口
        if (on_restore_) on_restore_();
        RemoveTrayIcon();
        ShowWindow(hwnd, SW_SHOW);
        ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
        return true;
      case WM_RBUTTONUP: {
        // 右键菜单：显示 / 退出
        POINT pt;
        GetCursorPos(&pt);
        HMENU menu = CreatePopupMenu();
        AppendMenu(menu, MF_STRING, IDM_RESTORE, L"显示 FlTraeRelay");
        AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenu(menu, MF_STRING, IDM_EXIT, L"退出");
        SetForegroundWindow(hwnd);  // 菜单能接收点击消失消息的必要条件
        int cmd = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY,
                                 pt.x, pt.y, 0, hwnd, nullptr);
        DestroyMenu(menu);
        if (cmd == IDM_RESTORE) {
          if (on_restore_) on_restore_();
          RemoveTrayIcon();
          ShowWindow(hwnd, SW_SHOW);
          ShowWindow(hwnd, SW_RESTORE);
          SetForegroundWindow(hwnd);
        } else if (cmd == IDM_EXIT) {
          if (on_exit_request_) on_exit_request_();
        }
        return true;
      }
      default:
        break;
    }
  }
  return false;
}
