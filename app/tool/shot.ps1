# shot.ps1 - screenshot a window by title, optionally click client coords first
param(
  [Parameter(Mandatory=$true)][string]$Out,
  [string]$Title = "fltrae_relay",
  [int]$ClickX = -1,
  [int]$ClickY = -1,
  [int]$WaitMs = 800
)

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@

[Win]::SetProcessDPIAware() | Out-Null
$hwnd = [Win]::FindWindowW([NullString]::Value, $Title)
if ($hwnd -eq [IntPtr]::Zero) { Write-Error "window not found: $Title"; exit 1 }
[Win]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 200

$rect = New-Object Win+RECT
[Win]::GetClientRect($hwnd, [ref]$rect) | Out-Null
$w = $rect.R - $rect.L
$h = $rect.B - $rect.T

if ($ClickX -ge 0) {
  # 点击坐标按截图（物理像素）传入；窗口客户区亦为物理像素（DPI aware）。
  # ClientToScreen 需要的是调用进程的逻辑坐标：PowerShell 未声明 DPI aware
  # 时系统按 96 DPI 处理，因此物理坐标需除以缩放比。
  $p = New-Object Win+POINT
  $p.X = $ClickX; $p.Y = $ClickY
  [Win]::ClientToScreen($hwnd, [ref]$p) | Out-Null
  # ClientToScreen 在非 DPI aware 进程里已做了一次换算，结果仍偏大，
  # 实测 200% DPI 下再除以 2 落点才正确；其他缩放按 (dpi/96) 推算。
  $dpi = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction SilentlyContinue).AppliedDPI
  if (-not $dpi) { $dpi = 96 }
  $scale = $dpi / 96
  [Win]::SetCursorPos([int]($p.X / $scale), [int]($p.Y / $scale)) | Out-Null
  Start-Sleep -Milliseconds 100
  [Win]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)  # LEFTDOWN
  [Win]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)  # LEFTUP
  Start-Sleep -Milliseconds $WaitMs
}

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc()
[Win]::PrintWindow($hwnd, $dc, 2) | Out-Null   # PW_RENDERFULLCONTENT
$g.ReleaseHdc($dc)
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "saved $Out ($w x $h)"
