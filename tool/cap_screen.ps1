# Launch-time render check: force the app to foreground reliably, then capture its screen area
param([string]$OutPath = 'E:\Folders\Trea\FlTraeRelay\shot_check.png')

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WCap {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

[WCap]::SetProcessDPIAware() | Out-Null
$proc = Get-Process fltrae_relay -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Write-Output 'no process'; exit }
$h = $proc.MainWindowHandle

# minimize+restore forces real foreground
[WCap]::ShowWindow($h, 6) | Out-Null
Start-Sleep -Milliseconds 400
[WCap]::ShowWindow($h, 9) | Out-Null
[WCap]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 1500

if ([WCap]::GetForegroundWindow() -ne $h) { Write-Output 'warn: not foreground' }

$r = New-Object WCap+RECT
[WCap]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.Right - $r.Left
$hh = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
$bmp.Save($OutPath)
$g.Dispose(); $bmp.Dispose()
Write-Output "saved $OutPath ($w x $hh)"
