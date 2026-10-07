# Focus FlTraeRelay once, then click through bottom tabs and capture each page
param([string]$Dir = 'E:\Folders\Trea\FlTraeRelay')

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Win32Shot {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Capture($h, $path) {
    $rect = New-Object Win32Shot+RECT
    [Win32Shot]::GetWindowRect($h, [ref]$rect) | Out-Null
    $w = $rect.Right - $rect.Left
    $hh = $rect.Bottom - $rect.Top
    $bmp = New-Object System.Drawing.Bitmap $w, $hh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [Win32Shot]::PrintWindow($h, $hdc, 2)
    $g.ReleaseHdc($hdc)
    if (-not $ok) { throw 'PrintWindow failed' }
    $bmp.Save($path)
    $g.Dispose()
    $bmp.Dispose()
    Write-Output "saved $path"
}

function ClickAt($h, $x, $y) {
    $rect = New-Object Win32Shot+RECT
    [Win32Shot]::GetWindowRect($h, [ref]$rect) | Out-Null
    [Win32Shot]::SetCursorPos($rect.Left + $x, $rect.Top + $y) | Out-Null
    Start-Sleep -Milliseconds 250
    [Win32Shot]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
    [Win32Shot]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
}

[Win32Shot]::SetProcessDPIAware() | Out-Null
$proc = $null
foreach ($c in (Get-Process fltrae_relay -ErrorAction SilentlyContinue)) {
    if ($c.MainWindowHandle -ne 0) { $proc = $c; break }
}
if (-not $proc) { throw 'fltrae_relay window not ready' }
$h = [IntPtr]$proc.MainWindowHandle

# minimize+restore once to force foreground
[Win32Shot]::ShowWindow($h, 6) | Out-Null
Start-Sleep -Milliseconds 500
[Win32Shot]::ShowWindow($h, 9) | Out-Null
[Win32Shot]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 1200

# overview -> usage tab (x=1237) -> settings tab (x=1715), then back to models tab (x=760)
Capture $h "$Dir\shot_usage.png"
ClickAt $h 1237 1330
Start-Sleep -Milliseconds 1500
Capture $h "$Dir\shot_usage.png"
ClickAt $h 1715 1330
Start-Sleep -Milliseconds 1500
Capture $h "$Dir\shot_settings.png"
