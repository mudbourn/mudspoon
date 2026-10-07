# Watches for the ctfmon fail fast crash #
    # Logs every foreground and keyboard focus change, and when a fail fast dialog
    # appears it dumps the crashed process and snapshots the host logs.
    # Usage: powershell -ExecutionPolicy Bypass -File test\ctf_watch.ps1
    # Run it from an elevated shell, or the dump step fails with access denied.
param(
    [string]$Out = (Join-Path ([Environment]::GetFolderPath("Desktop")) "ctf_watch"),
    [int]$PollMs = 30
)

$ErrorActionPreference = "Stop"

# Win32 #
    Add-Type @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class CtfWatch {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO {
        public uint cbSize;
        public uint flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetGUIThreadInfo(uint thread, ref GUITHREADINFO info);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int max);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);

    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);

    [DllImport("dbghelp.dll", SetLastError = true)]
    public static extern bool MiniDumpWriteDump(IntPtr process, uint pid, SafeFileHandle file, uint type, IntPtr exception, IntPtr user, IntPtr callback);

    public static string Text(IntPtr hwnd) {
        var sb = new StringBuilder(256);

        GetWindowText(hwnd, sb, 256);

        return sb.ToString();
    }

    public static string Class(IntPtr hwnd) {
        var sb = new StringBuilder(256);

        GetClassName(hwnd, sb, 256);

        return sb.ToString();
    }

    public static IntPtr Focus() {
        var info = new GUITHREADINFO();

        info.cbSize = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));

        return GetGUIThreadInfo(0, ref info) ? info.hwndFocus : IntPtr.Zero;
    }

    public static IntPtr FindTitle(string fragment) {
        IntPtr found = IntPtr.Zero;

        EnumWindows((h, l) => {
            if (IsWindowVisible(h) && Text(h).Contains(fragment)) {
                found = h;
                return false;
            }

            return true;
        }, IntPtr.Zero);

        return found;
    }

    public static string Dump(uint pid, string path) {
        IntPtr h = OpenProcess(0x0410, false, pid);

        if (h == IntPtr.Zero) return "open failed, error " + Marshal.GetLastWin32Error();

        try {
            using (var fs = new FileStream(path, FileMode.Create)) {
                bool ok = MiniDumpWriteDump(h, pid, fs.SafeFileHandle, 0x1826, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

                return ok ? "ok" : "dump failed, error " + Marshal.GetLastWin32Error();
            }
        } finally {
            CloseHandle(h);
        }
    }
}
'@
# END #

# Helpers #
    New-Item -ItemType Directory -Force -Path $Out | Out-Null

    $log = Join-Path $Out ("ctf_watch_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

    function Write-Log($line) {
        $stamp = (Get-Date).ToString("HH:mm:ss.fff")

        Add-Content -Path $log -Value "$stamp $line"

        Write-Host "$stamp $line"
    }

    function Describe($hwnd) {
        if ($hwnd -eq [IntPtr]::Zero) { return "none" }

        $procId = [uint32]0

        [void][CtfWatch]::GetWindowThreadProcessId($hwnd, [ref]$procId)

        $name = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName

        return "{0} pid={1} {2} class='{3}' title='{4}'" -f $hwnd, $procId, $name, [CtfWatch]::Class($hwnd), [CtfWatch]::Text($hwnd)
    }

    function Get-CtfPids {
        return @(Get-Process ctfmon -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) -join ","
    }

    function Save-HostLogs($dir) {
        $roots = @(
            (Join-Path $env:LOCALAPPDATA "Mudspoon\.hammerspoon"),
            (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ".hammerspoon")
        )

        foreach ($root in $roots) {
            foreach ($rel in @("hammerspoon.log", "data\stderr.log", "data\probe.txt")) {
                $src = Join-Path $root $rel

                if (Test-Path $src) {
                    $tag = (Split-Path $root -Parent | Split-Path -Leaf) + "_" + ($rel -replace "[\\/]", "_")

                    Copy-Item $src (Join-Path $dir $tag) -Force
                }
            }
        }
    }
# END #

# Watch loop #
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    Write-Log ("watching, elevated={0}, ctfmon pids={1}, log={2}" -f $admin, (Get-CtfPids), $log)

    if (-not $admin) { Write-Log "not elevated: focus is logged but the crash dump will fail" }

    $lastFg = [IntPtr]::Zero
    $lastFocus = [IntPtr]::Zero
    $lastCtf = Get-CtfPids
    $dumped = @{}

    while ($true) {
        $fg = [CtfWatch]::GetForegroundWindow()
        $focus = [CtfWatch]::Focus()

        if ($fg -ne $lastFg) {
            Write-Log ("foreground -> " + (Describe $fg))

            $lastFg = $fg
        }

        if ($focus -ne $lastFocus) {
            Write-Log ("focus      -> " + (Describe $focus))

            $lastFocus = $focus
        }

        $ctf = Get-CtfPids

        if ($ctf -ne $lastCtf) {
            Write-Log "ctfmon pids $lastCtf -> $ctf"

            $lastCtf = $ctf
        }

        $dialog = [CtfWatch]::FindTitle("Fail Fast Exception")

        if ($dialog -ne [IntPtr]::Zero -and -not $dumped.ContainsKey([string]$dialog)) {
            $dumped[[string]$dialog] = $true

            $title = [CtfWatch]::Text($dialog)
            $exe = ($title -split " - ")[0] -replace "\.exe$", ""
            $dir = Join-Path $Out ("crash_{0:yyyyMMdd_HHmmss}" -f (Get-Date))

            New-Item -ItemType Directory -Force -Path $dir | Out-Null

            Write-Log "FAIL FAST dialog: '$title'"

            foreach ($p in @(Get-Process $exe -ErrorAction SilentlyContinue)) {
                $dmp = Join-Path $dir ("{0}_{1}.dmp" -f $exe, $p.Id)
                $result = [CtfWatch]::Dump([uint32]$p.Id, $dmp)

                Write-Log "dump $exe pid=$($p.Id): $result"
            }

            Save-HostLogs $dir

            Copy-Item $log $dir

            Write-Log "crash bundle: $dir (leave the dialog open until the dump line above says ok)"
        }

        Start-Sleep -Milliseconds $PollMs
    }
# END #
