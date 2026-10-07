# List all top-level windows of the fltrae_relay process
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class EW {
    public delegate bool CB(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(CB cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public struct RECT { public int Left, Top, Right, Bottom; }
    public static uint Target;
    public static bool Cb(IntPtr h, IntPtr l) {
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        if (pid == Target) {
            var t = new StringBuilder(256);
            var c = new StringBuilder(256);
            GetWindowTextW(h, t, 256);
            GetClassNameW(h, c, 256);
            RECT r;
            GetWindowRect(h, out r);
            string rect = (r.Right - r.Left) + "x" + (r.Bottom - r.Top);
            Console.WriteLine("hwnd=" + h + " vis=" + IsWindowVisible(h) + " class=" + c + " title=" + t + " rect=" + rect);
        }
        return true;
    }
}
'@
$p = Get-Process fltrae_relay -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { Write-Output 'no process'; exit }
Write-Output "pid=$($p.Id) mainHandle=$($p.MainWindowHandle)"
[EW]::Target = $p.Id
$cb = [EW+CB]{ param($h, $l) [EW]::Cb($h, $l) | Out-Null; return $true }
[EW]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
