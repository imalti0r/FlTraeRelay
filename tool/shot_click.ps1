# Single click + capture
param([int]$ClickX, [int]$ClickY, [string]$OutPath)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Win32Shot2 {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public const uint WHEEL = 0x0800;
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type -AssemblyName System.Drawing

[Win32Shot2]::SetProcessDPIAware() | Out-Null
$proc = $null
foreach ($c in (Get-Process fltrae_relay -ErrorAction SilentlyContinue)) {
    if ($c.MainWindowHandle -ne 0) { $proc = $c; break }
}
if (-not $proc) { throw 'fltrae_relay window not ready' }
$h = [IntPtr]$proc.MainWindowHandle
# NOMOVE(0x2)|NOSIZE(0x1) → move window to (100,100) to dodge any overlapping transparent window
[Win32Shot2]::SetWindowPos($h, [IntPtr]::Zero, 100, 100, 0, 0, 0x1 -bor 0x2) | Out-Null
[Win32Shot2]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 800

$rect = New-Object Win32Shot2+RECT
[Win32Shot2]::GetWindowRect($h, [ref]$rect) | Out-Null
[Win32Shot2]::SetCursorPos($rect.Left + $ClickX, $rect.Top + $ClickY) | Out-Null
Start-Sleep -Milliseconds 400
[Win32Shot2]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 120
[Win32Shot2]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 1500

# wheel-scroll down over the page (dwData signed int)
for ($i = 0; $i -lt 8; $i++) {
    [Win32Shot2]::mouse_event([Win32Shot2]::WHEEL, 0, 0, -240, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Milliseconds 1200

$w = $rect.Right - $rect.Left
$hh = $rect.Bottom - $rect.Top
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [Win32Shot2]::PrintWindow($h, $hdc, 2)
$g.ReleaseHdc($hdc)
if (-not $ok) { throw 'PrintWindow failed' }
$bmp.Save($OutPath)
$g.Dispose()
$bmp.Dispose()
Write-Output "saved $OutPath"
