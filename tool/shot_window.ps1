# Force FlTraeRelay to foreground (minimize + restore trick), send keys, capture
param(
    [string]$Keys = '',
    [int]$ClickX = -1,
    [int]$ClickY = -1,
    [int]$DelayMs = 1500,
    [string]$OutPath = 'E:\Folders\Trea\FlTraeRelay\shot.png'
)

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

[Win32Shot]::SetProcessDPIAware() | Out-Null
$proc = $null
foreach ($c in (Get-Process fltrae_relay -ErrorAction SilentlyContinue)) {
    if ($c.MainWindowHandle -ne 0) { $proc = $c; break }
}
if (-not $proc) { throw 'fltrae_relay window not ready' }
$h = [IntPtr]$proc.MainWindowHandle

if ($Keys -ne '' -or ($ClickX -ge 0 -and $ClickY -ge 0)) {
    # minimize then restore forces the window to foreground with focus
    [Win32Shot]::ShowWindow($h, 6) | Out-Null
    Start-Sleep -Milliseconds 400
    [Win32Shot]::ShowWindow($h, 9) | Out-Null
    [Win32Shot]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 800
    if ($ClickX -ge 0 -and $ClickY -ge 0) {
        $rect2 = New-Object Win32Shot+RECT
        [Win32Shot]::GetWindowRect($h, [ref]$rect2) | Out-Null
        [Win32Shot]::SetCursorPos($rect2.Left + $ClickX, $rect2.Top + $ClickY) | Out-Null
        Start-Sleep -Milliseconds 200
        # LEFTDOWN=0x02 LEFTUP=0x04
        [Win32Shot]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
        [Win32Shot]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
    }
    else {
        [System.Windows.Forms.SendKeys]::SendWait($Keys)
    }
    Start-Sleep -Milliseconds $DelayMs
}
else {
    [Win32Shot]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 800
}

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
$bmp.Save($OutPath)
$g.Dispose()
$bmp.Dispose()
Write-Output "saved $OutPath ($w x $hh)"
