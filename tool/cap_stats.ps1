# Capture the stats card strip of the usage page
param([string]$OutPath = 'E:\Folders\Trea\FlTraeRelay\shot_stats_live.png')

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WS {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type -AssemblyName System.Drawing

[WS]::SetProcessDPIAware() | Out-Null
$p = Get-Process fltrae_relay | Select-Object -First 1
[WS]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 500
$r = New-Object WS+RECT
[WS]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
$w = $r.Right - $r.Left
$bmp = New-Object System.Drawing.Bitmap $w, 380
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top + 150, 0, 0, (New-Object System.Drawing.Size $w, 380))
$bmp.Save($OutPath)
$g.Dispose(); $bmp.Dispose()
Write-Output "saved $OutPath"
