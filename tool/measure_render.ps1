# Launch app, then poll the screen every 1s sampling a center pixel until UI renders; report delay
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WPoll {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

[WPoll]::SetProcessDPIAware() | Out-Null
$proc = Get-Process fltrae_relay -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Write-Output 'no process'; exit }
$h = $proc.MainWindowHandle
[WPoll]::SetForegroundWindow($h) | Out-Null

$sw = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 1000
    $r = New-Object WPoll+RECT
    [WPoll]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.Right - $r.Left
    $hh = $r.Bottom - $r.Top
    if ($w -le 0) { continue }
    $bmp = New-Object System.Drawing.Bitmap 1, 1
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left + [int]($w * 0.5), $r.Top + [int]($hh * 0.4), 0, 0, (New-Object System.Drawing.Size 1, 1))
    $c = $bmp.GetPixel(0, 0)
    $g.Dispose()
    $bmp.Dispose()
    $isBg = ([Math]::Abs($c.R - 8) -lt 6) -and ([Math]::Abs($c.G - 14) -lt 6) -and ([Math]::Abs($c.B - 18) -lt 6)
    Write-Output ("t={0,3}s pixel=({1},{2},{3}){4}" -f $sw.Elapsed.Seconds, $c.R, $c.G, $c.B, $(if ($isBg) { ' (bg)' } else { ' RENDERED' }))
    if (-not $isBg) { break }
}
