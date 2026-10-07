# Drag the glass title bar and verify the window moved; then capture screen area
param([string]$OutPath = 'E:\Folders\Trea\FlTraeRelay\shot_drag.png')

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WDrag {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, UIntPtr dwExtraInfo);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

[WDrag]::SetProcessDPIAware() | Out-Null
$proc = Get-Process fltrae_relay -ErrorAction Stop | Select-Object -First 1
$h = $proc.MainWindowHandle
[WDrag]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 800

$r0 = New-Object WDrag+RECT
[WDrag]::GetWindowRect($h, [ref]$r0) | Out-Null
$beforeX = $r0.Left; $beforeY = $r0.Top

# press on title bar text area (inside HTCAPTION zone), drag by (+250, +160)
$grabX = $r0.Left + 300
$grabY = $r0.Top + 48
[WDrag]::SetCursorPos($grabX, $grabY) | Out-Null
Start-Sleep -Milliseconds 250
[WDrag]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)   # left down
Start-Sleep -Milliseconds 150
for ($i = 1; $i -le 10; $i++) {
    [WDrag]::SetCursorPos($grabX + 25 * $i, $grabY + 16 * $i) | Out-Null
    Start-Sleep -Milliseconds 40
}
Start-Sleep -Milliseconds 200
[WDrag]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)   # left up
Start-Sleep -Milliseconds 800

$r1 = New-Object WDrag+RECT
[WDrag]::GetWindowRect($h, [ref]$r1) | Out-Null
$dx = $r1.Left - $beforeX
$dy = $r1.Top - $beforeY
Write-Output "moved by ($dx, $dy)"

# capture the moved window from the screen
$w = $r1.Right - $r1.Left
$hh = $r1.Bottom - $r1.Top
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r1.Left, $r1.Top, 0, 0, $bmp.Size)
$bmp.Save($OutPath)
$g.Dispose(); $bmp.Dispose()
Write-Output "saved $OutPath"
